//
//  SearchRanker.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//Updated 9/27 - 7:45

import Foundation

/// Drop-in fuzzy ranking for your existing TMDB results.
/// Usage:
/// let raw = try await TMDBService.searchTitles(query: q, ... )
/// let ranked = SearchRanker.rank(query: q, items: raw, limit: 60)
/// self.results = ranked
struct SearchRanker {

    // Words we ignore for matching (helps with titles like "The Office", "A Quiet Place")
    private static let stopwords: Set<String> = [
        "the","a","an","of","and","or","to","in","on","at","for","with","from"
    ]

    /// Main entry: rank + lightly filter your results.
    static func rank(query: String, items: [TitleItem], limit: Int = 60) -> [TitleItem] {
        let qNorm = normalize(query)
        if qNorm.isEmpty { return Array(items.prefix(limit)) }

        // Extract year tokens in query (e.g., "Dune 2021")
        let queryYear = extractYear(qNorm)

        // If user typed "the office", also try "office".
        let altQueries = alternateQueries(for: qNorm)

        // Precompute normalized titles & token sets (avoid repeated work per alt query)
        var normTitleByKey = [String: String]()
        normTitleByKey.reserveCapacity(items.count)
        var tokenSetByKey = [String: Set<String>]()
        tokenSetByKey.reserveCapacity(items.count)

        func key(for item: TitleItem) -> String {
            // id is unique across TMDB for both movie/tv; include mediaType to be safe.
            "\(item.id)#\(item.mediaType.rawValue)"
        }

        for it in items {
            let k = key(for: it)
            let t = normalize(it.name)
            normTitleByKey[k] = t
            tokenSetByKey[k] = tokenSet(t)
        }

        // Score each item; keep if it clears threshold for any alt query.
        var scored: [(TitleItem, Int)] = []
        scored.reserveCapacity(items.count)

        for it in items {
            let k = key(for: it)
            guard let t = normTitleByKey[k],
                  let titleTokens = tokenSetByKey[k] else { continue }

            var best = 0

            for qAlt in altQueries {
                let qTokens = tokenSet(qAlt)

                // Base token-set similarity (Jaccard-ish, 0..100)
                let j = jaccardScore(a: qTokens, b: titleTokens)

                // String boosts (cheap contains/prefix with start-of-word preference)
                var boost = 0
                if t == qAlt { boost += 40 }               // exact (normalized) match
                else if hasWordPrefix(haystack: t, needle: qAlt) { boost += 25 } // word-start prefix
                else if containsWord(haystack: t, needle: qAlt) { boost += 15 }  // whole-word contains
                else if t.contains(qAlt) { boost += 10 }    // raw contains

                // Small edit-distance boost for short queries (≤ 24 chars) and small typos (≤2)
                if qAlt.count >= 3 && qAlt.count <= 24 {
                    let ed = cappedEditDistance(qAlt, t, maxDistance: 2)
                    if ed <= 2 { boost += (2 - ed + 1) * 5 } // 2→5, 1→10, 0 already covered above
                }

                // Year alignment (if query includes a year and item.year matches)
                if let qy = queryYear, let iy = Int(it.year), qy == iy { boost += 8 }

                // Popularity / vote count weight (optional; safe if nil)
                let popBoost = scoreFromPopularity(it)

                let total = min(100, j + boost + popBoost)
                if total > best { best = total }
                // Quick escape if already near max
                if best >= 98 { break }
            }

            // Keep permissively; list is re-ordered anyway.
            if best >= 20 {
                scored.append((it, best))
            }
        }

        // Sort by score DESC, then by TMDB votes, then rating, then name for stability.
        scored.sort { (lhs, rhs) in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let lv = lhs.0.tmdbVoteCount ?? 0
            let rv = rhs.0.tmdbVoteCount ?? 0
            if lv != rv { return lv > rv }
            let lr = lhs.0.tmdbRating ?? 0
            let rr = rhs.0.tmdbRating ?? 0
            if lr != rr { return lr > rr }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }

        // Dedup by (id + mediaType)
        var seen = Set<String>(); seen.reserveCapacity(scored.count)
        var out: [TitleItem] = []; out.reserveCapacity(min(limit, scored.count))
        for (item, _) in scored {
            let k = "\(item.id)#\(item.mediaType.rawValue)"
            if seen.insert(k).inserted {
                out.append(item)
                if out.count >= limit { break }
            }
        }
        return out
    }

    // MARK: - Helpers (fast path)

    /// Lowercased, diacritic-insensitive, alnum + spaces only, collapsed spaces.
    private static func normalize(_ s: String) -> String {
        if s.isEmpty { return "" }
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var out = [Character](); out.reserveCapacity(folded.count)
        var lastSpace = false
        for u in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) {
                out.append(Character(u))
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        if out.last == " " { out.removeLast() }
        return String(out)
    }

    private static func tokenSet(_ s: String) -> Set<String> {
        // Avoid splitting to lots of tiny strings when we can.
        var set = Set<String>(); set.reserveCapacity(8)
        var current = [Character](); current.reserveCapacity(12)
        func flush() {
            if !current.isEmpty {
                let tok = String(current)
                if !stopwords.contains(tok) { set.insert(tok) }
                current.removeAll(keepingCapacity: true)
            }
        }
        for ch in s {
            if ch == " " {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()
        return set
    }

    private static func alternateQueries(for q: String) -> [String] {
        // 1) original
        // 2) dropped leading stopword (e.g., "the office" -> "office")
        var alts: [String] = [q]
        if let first = q.split(separator: " ").first, stopwords.contains(String(first)) {
            let dropped = q.split(separator: " ").dropFirst().joined(separator: " ")
            if !dropped.isEmpty { alts.append(dropped) }
        }
        // Return unique (order doesn’t matter much)
        if alts.count == 2 && alts[0] == alts[1] { return [alts[0]] }
        return alts
    }

    // Simple Jaccard on token sets, scaled to 0..100
    private static func jaccardScore(a: Set<String>, b: Set<String>) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        let inter = a.intersection(b).count
        let uni = a.union(b).count
        return Int(Double(inter) / Double(max(1, uni)) * 100.0)
    }

    /// True if `needle` occurs at a word boundary in `haystack`.
    private static func containsWord(haystack: String, needle: String) -> Bool {
        if haystack.isEmpty || needle.isEmpty { return false }
        // Cheap scan without regex
        let h = haystack
        let n = needle
        // iterate indices where a word starts in h and try to match whole needle
        var idx = h.startIndex
        while idx < h.endIndex {
            // word start if at start or previous is space
            if idx == h.startIndex || h[h.index(before: idx)] == " " {
                if h[idx...].hasPrefix(n) {
                    let end = h.index(idx, offsetBy: n.count, limitedBy: h.endIndex) ?? h.endIndex
                    // end must be end-of-string or space
                    if end == h.endIndex || (end < h.endIndex && h[end] == " ") {
                        return true
                    }
                }
            }
            // advance to next space or end
            if let space = h[idx...].firstIndex(of: " ") {
                idx = h.index(after: space)
            } else {
                break
            }
        }
        return false
    }

    /// True if `needle` matches a prefix starting at any word boundary in `haystack`.
    private static func hasWordPrefix(haystack: String, needle: String) -> Bool {
        if haystack.isEmpty || needle.isEmpty { return false }
        let h = haystack
        let n = needle
        var idx = h.startIndex
        while idx < h.endIndex {
            if idx == h.startIndex || h[h.index(before: idx)] == " " {
                if h[idx...].hasPrefix(n) { return true }
            }
            if let space = h[idx...].firstIndex(of: " ") {
                idx = h.index(after: space)
            } else {
                break
            }
        }
        return false
    }

    // Lightweight capped Levenshtein with early abandon when distance > maxDistance
    private static func cappedEditDistance(_ a: String, _ b: String, maxDistance: Int) -> Int {
        // Swap to ensure a is shorter
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count, m = bChars.count
        if abs(n - m) > maxDistance { return maxDistance + 1 } // quick bound
        if n == 0 { return min(m, maxDistance + 1) }
        if m == 0 { return min(n, maxDistance + 1) }

        // Ukkonen band: only compute within ±maxDistance of diagonal
        let band = maxDistance
        let INF = maxDistance + 1
        var prev = [Int](repeating: INF, count: m + 1)
        var curr = [Int](repeating: INF, count: m + 1)

        // init prev within band
        prev[0] = 0
        for j in 1...m { prev[j] = j <= band ? j : INF }

        for i in 1...n {
            // compute j range in band
            let from = max(1, i - band)
            let to   = min(m, i + band)

            // Set outside band to INF; seed left cell
            curr[0] = i <= band ? i : INF
            if from > 1 { curr[from - 1] = INF }

            for j in from...to {
                let cost = (aChars[i - 1] == bChars[j - 1]) ? 0 : 1
                let del = prev[j] + 1
                let ins = curr[j - 1] + 1
                let sub = prev[j - 1] + cost
                var v = del < ins ? del : ins
                if sub < v { v = sub }
                curr[j] = v
            }

            // Early abandon if the minimal value in this row already exceeds maxDistance
            if curr[from...to].min() ?? INF > maxDistance { return maxDistance + 1 }

            swap(&prev, &curr)
        }

        return min(prev[m], maxDistance + 1)
    }

    private static func extractYear(_ s: String) -> Int? {
        // Find a 4-digit number that looks like a plausible year (1900...2100 just to be safe)
        var num = 0
        var found = false
        var count = 0
        for ch in s {
            if ch >= "0" && ch <= "9" {
                num = num * 10 + Int(ch.unicodeScalars.first!.value - 48)
                count += 1
                if count == 4 {
                    if (1900...2100).contains(num) { found = true; break }
                    // slide window (e.g., "12345")
                    num %= 1000
                    count = 3
                }
            } else {
                num = 0; count = 0
            }
        }
        return found ? num : nil
    }

    private static func scoreFromPopularity(_ item: TitleItem) -> Int {
        // Gentle boost to float “obvious” results like The Office (US)
        // Scale voteCount/log-ish to 0..20.
        guard let votes = item.tmdbVoteCount, votes > 0 else { return 0 }
        // log1p is a bit heavy; integer-ish approximation is fine
        let scaled = min(20, Int(log(Double(votes + 1)) * 4.0))
        return scaled
    }
}
