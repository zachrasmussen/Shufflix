//
//  SearchRanker.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Refactored: 2025-10-02
//

import Foundation

/// Drop-in fuzzy ranking for your existing TMDB results.
/// Usage:
///   let raw = try await TMDBService.searchTitles(query: q, ... )
///   let ranked = SearchRanker.rank(query: q, items: raw, limit: 60)
///   self.results = ranked

struct SearchRanker {

    // MARK: - Tunables

    /// Words to ignore during token similarity checks. Keep **lowercase**.
    private static let stopwords: Set<String> = [
        "the","a","an","of","and","or","to","in","on","at","for","with","from"
    ]

    private static let keepThreshold = 20      // minimal score to keep a candidate
    private static let maxReturn     = 80      // internal cap for ranked pool before trim to `limit`
    private static let maxEdit       = 2       // maximum Levenshtein distance considered

    // MARK: - Entry point

    static func rank(query: String, items: [TitleItem], limit: Int = 60) -> [TitleItem] {
        let qNorm = normalize(query)
        if qNorm.isEmpty { return Array(items.prefix(limit)) }

        // Pull an optional year token (e.g., "Dune 2021")
        let queryYear = extractYear(qNorm)

        // If user typed "the office", also try "office".
        let altQueries = alternateQueries(for: qNorm)

        // Precompute normalized titles & token sets once.
        var normByKey = [String: String]()
        normByKey.reserveCapacity(items.count)
        var tokensByKey = [String: Set<String>]()
        tokensByKey.reserveCapacity(items.count)

        @inline(__always)
        func key(_ it: TitleItem) -> String { "\(it.id)#\(it.mediaType.rawValue)" }

        for it in items {
            let k = key(it)
            let t = normalize(it.name)
            normByKey[k] = t
            tokensByKey[k] = tokenSet(t)
        }

        // Score
        var scored: [(TitleItem, Int)] = []
        scored.reserveCapacity(min(items.count, maxReturn))

        scoringLoop: for it in items.prefix(256) { // hard cap keeps us speedy for huge result sets
            let k = key(it)
            guard let t = normByKey[k], let tTokens = tokensByKey[k] else { continue }

            var best = 0
            for qAlt in altQueries {
                let qTokens = tokenSet(qAlt)

                // Base token-set similarity (Jaccard-ish, 0..100)
                let j = jaccardScore(a: qTokens, b: tTokens)

                // String boosts
                var boost = 0
                if t == qAlt { boost += 40 }                         // exact normalized match
                else if hasWordPrefix(in: t, needle: qAlt) { boost += 25 } // word-start prefix
                else if containsWord(in: t, needle: qAlt) { boost += 15 }  // whole-word contains
                else if t.contains(qAlt) { boost += 10 }             // raw contains

                // Small edit-distance boost for shortish queries and small typos (≤2)
                if (3...24).contains(qAlt.count) {
                    let ed = cappedEditDistance(qAlt, t, maxDistance: maxEdit)
                    if ed <= maxEdit { boost += (maxEdit - ed + 1) * 5 } // 2→5, 1→10
                }

                // Year alignment
                if let qy = queryYear, let iy = Int(it.year), qy == iy { boost += 8 }

                // Popularity / vote count weight (gentle)
                let pop = scoreFromPopularity(it)

                let total = min(100, j + boost + pop)
                if total > best { best = total }
                if best >= 98 { break } // near-perfect—no need to try other alts
            }

            if best >= keepThreshold {
                scored.append((it, best))
                if scored.count >= maxReturn { break scoringLoop }
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

        // Dedup by (id + mediaType) and trim to limit
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

    // MARK: - Normalize & tokenization

    /// Lowercased, diacritic-insensitive, alnum + single spaces only.
    @inline(__always)
    private static func normalize(_ s: String) -> String {
        if s.isEmpty { return "" }
        // Fold once; then construct a compacted buffer without allocating intermediate strings.
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var scalars = folded.unicodeScalars
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)

        var lastWasSpace = false
        for u in scalars {
            if CharacterSet.alphanumerics.contains(u) {
                out.append(u)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        // Trim trailing space
        if lastWasSpace, let last = out.popLast(), last == " " { /* popped */ }
        return String(out)
    }

    /// Token set excluding stopwords.
    private static func tokenSet(_ s: String) -> Set<String> {
        var set = Set<String>(); set.reserveCapacity(8)
        var current = String()
        current.reserveCapacity(12)

        @inline(__always)
        func flush() {
            if !current.isEmpty {
                if !stopwords.contains(current) { set.insert(current) }
                current.removeAll(keepingCapacity: true)
            }
        }

        for ch in s {
            if ch == " " { flush() } else { current.append(ch) }
        }
        flush()
        return set
    }

    // MARK: - Alternate queries

    private static func alternateQueries(for q: String) -> [String] {
        // 1) original
        // 2) dropped leading stopword (e.g., "the office" -> "office")
        guard let first = q.split(separator: " ").first else { return [q] }
        if stopwords.contains(String(first)) {
            let dropped = q.split(separator: " ").dropFirst().joined(separator: " ")
            return dropped.isEmpty ? [q] : Array(Set([q, dropped])) // tiny dedup
        }
        return [q]
    }

    // MARK: - Scoring helpers

    /// Simple Jaccard on token sets, scaled to 0..100
    @inline(__always)
    private static func jaccardScore(a: Set<String>, b: Set<String>) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        let inter = a.intersection(b).count
        let uni = a.union(b).count
        return Int((Double(inter) / Double(max(1, uni))) * 100.0)
    }

    /// True if `needle` occurs as a **whole word** inside `haystack`.
    private static func containsWord(in haystack: String, needle: String) -> Bool {
        if haystack.isEmpty || needle.isEmpty { return false }
        let h = haystack
        let n = needle
        var idx = h.startIndex
        while idx < h.endIndex {
            // Word start if at start or previous is space
            if idx == h.startIndex || h[h.index(before: idx)] == " " {
                if h[idx...].hasPrefix(n) {
                    let end = h.index(idx, offsetBy: n.count, limitedBy: h.endIndex) ?? h.endIndex
                    // end must be end-of-string or space
                    if end == h.endIndex || (end < h.endIndex && h[end] == " ") { return true }
                }
            }
            // Advance to next space (or end)
            if let space = h[idx...].firstIndex(of: " ") {
                idx = h.index(after: space)
            } else {
                break
            }
        }
        return false
    }

    /// True if `needle` matches a prefix starting at **any** word boundary in `haystack`.
    private static func hasWordPrefix(in haystack: String, needle: String) -> Bool {
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

    /// Levenshtein distance with **Ukkonen band**; early-abandons if > maxDistance.
    private static func cappedEditDistance(_ a: String, _ b: String, maxDistance: Int) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let n = aChars.count, m = bChars.count
        if abs(n - m) > maxDistance { return maxDistance + 1 } // quick bound
        if n == 0 { return min(m, maxDistance + 1) }
        if m == 0 { return min(n, maxDistance + 1) }

        let band = maxDistance
        let INF = maxDistance + 1
        var prev = [Int](repeating: INF, count: m + 1)
        var curr = [Int](repeating: INF, count: m + 1)

        prev[0] = 0
        for j in 1...m { prev[j] = j <= band ? j : INF }

        for i in 1...n {
            let from = max(1, i - band)
            let to   = min(m, i + band)

            curr[0] = i <= band ? i : INF
            if from > 1 { curr[from - 1] = INF }

            var rowMin = INF
            for j in from...to {
                let cost = (aChars[i - 1] == bChars[j - 1]) ? 0 : 1
                let del = prev[j] + 1
                let ins = curr[j - 1] + 1
                let sub = prev[j - 1] + cost
                var v = del < ins ? del : ins
                if sub < v { v = sub }
                curr[j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > maxDistance { return maxDistance + 1 } // early abandon
            swap(&prev, &curr)
        }
        return min(prev[m], maxDistance + 1)
    }

    /// Extracts a plausible 4-digit year (1900…2100) from a normalized string.
    private static func extractYear(_ s: String) -> Int? {
        var num = 0, count = 0
        for ch in s {
            if ch >= "0" && ch <= "9" {
                num = num * 10 + Int(ch.unicodeScalars.first!.value - 48)
                count += 1
                if count == 4 {
                    if (1900...2100).contains(num) { return num }
                    num %= 1000; count = 3 // slide window
                }
            } else {
                num = 0; count = 0
            }
        }
        return nil
    }

    /// Gentle popularity weighting: ~log(votes), clamped to [0, 20].
    private static func scoreFromPopularity(_ item: TitleItem) -> Int {
        guard let votes = item.tmdbVoteCount, votes > 0 else { return 0 }
        // Using a soft curve that grows quickly then levels off:
        // 100 votes ≈ 9, 1k ≈ 14, 10k ≈ 18, 100k ≈ 20
        let v = log(Double(votes)) // natural log
        let scaled = Int(4.5 * v - 9.0)
        return max(0, min(20, scaled))
    }
}
