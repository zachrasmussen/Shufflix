//
//  SearchRanker.swift
//  Shufflix
//
//  Production-hardened: 2025-10-03
//

import Foundation

/// Fuzzy ranking and recall-first search.
/// Designed to be forgiving: handles stopwords, regions (US/UK), typos, and loose matches.
/// Example:
///   let raw = try await TMDBService.searchTitles(query: q)
///   let ranked = SearchRanker.rank(query: q, items: raw, limit: 60)
///
struct SearchRanker {

  // MARK: - Tunables

  private static let stopwords: Set<String> = [
    "the","a","an","of","and","or","to","in","on","at","for","with","from"
  ]

  private static let keepThreshold = 10      // lowered from 20 → recall first
  private static let maxReturn     = 100     // wider pool before trim
  private static let maxEdit       = 2       // max Levenshtein distance

  // MARK: - Entry point

  static func rank(query: String, items: [TitleItem], limit: Int = 60) -> [TitleItem] {
    let qNorm = normalize(query)
    if qNorm.isEmpty { return Array(items.prefix(limit)) }

    let queryYear = extractYear(qNorm)
    let altQueries = alternateQueries(for: qNorm)

    // Precompute normalized title + tokens
    var normByKey = [String: String](minimumCapacity: items.count)
    var tokensByKey = [String: Set<String>](minimumCapacity: items.count)

    @inline(__always)
    func key(_ it: TitleItem) -> String { "\(it.id)#\(it.mediaType.rawValue)" }

    for it in items {
      let k = key(it)
      let t = normalize(it.name)
      normByKey[k] = t
      tokensByKey[k] = tokenSet(t)
    }

    // Score candidates
    var scored: [(TitleItem, Int)] = []
    scored.reserveCapacity(min(items.count, maxReturn))

    scoringLoop: for it in items.prefix(512) { // slightly higher cap
      let k = key(it)
      guard let t = normByKey[k], let tTokens = tokensByKey[k] else { continue }

      var best = 0
      for qAlt in altQueries {
        let qTokens = tokenSet(qAlt)

        // Base similarity
        let j = jaccardScore(a: qTokens, b: tTokens)

        var boost = 0
        if t == qAlt { boost += 50 }                              // exact
        else if hasWordPrefix(in: t, needle: qAlt) { boost += 30 } // prefix
        else if containsWord(in: t, needle: qAlt) { boost += 20 }  // whole word
        else if t.contains(qAlt) { boost += 15 }                   // raw contains

        // Typo tolerance (up to 2 edits)
        if (3...32).contains(qAlt.count) {
          let ed = cappedEditDistance(qAlt, t, maxDistance: maxEdit)
          if ed <= maxEdit { boost += (maxEdit - ed + 1) * 8 } // 2→8, 1→16
        }

        // Year alignment
        if let qy = queryYear, let iy = Int(it.year), qy == iy { boost += 8 }

        // Popularity weight
        let pop = scoreFromPopularity(it)

        let total = min(100, j + boost + pop)
        if total > best { best = total }
        if best >= 98 { break } // near-perfect
      }

      if best >= keepThreshold {
        scored.append((it, best))
        if scored.count >= maxReturn { break scoringLoop }
      }
    }

    // Sort by score DESC, then TMDB votes, then rating, then name
    scored.sort {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      let lv = $0.0.tmdbVoteCount ?? 0, rv = $1.0.tmdbVoteCount ?? 0
      if lv != rv { return lv > rv }
      let lr = $0.0.tmdbRating ?? 0, rr = $1.0.tmdbRating ?? 0
      if lr != rr { return lr > rr }
      return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
    }

    // Dedup and trim
    var seen = Set<String>(); seen.reserveCapacity(scored.count)
    var out: [TitleItem] = []; out.reserveCapacity(min(limit, scored.count))
    for (item, _) in scored {
      let k = key(item)
      if seen.insert(k).inserted {
        out.append(item)
        if out.count >= limit { break }
      }
    }
    return out
  }

  // ===========================================================
  // MARK: - Normalization
  // ===========================================================

  @inline(__always)
  private static func normalize(_ s: String) -> String {
    if s.isEmpty { return "" }
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    var scalars = folded.unicodeScalars
    var out = String.UnicodeScalarView()
    out.reserveCapacity(scalars.count)

    var lastWasSpace = false
    for u in scalars {
      if CharacterSet.alphanumerics.contains(u) {
        out.append(u); lastWasSpace = false
      } else if !lastWasSpace {
        out.append(" "); lastWasSpace = true
      }
    }
    if lastWasSpace, let last = out.popLast(), last == " " {}
    return String(out)
  }

  private static func tokenSet(_ s: String) -> Set<String> {
    var set = Set<String>(); set.reserveCapacity(8)
    for word in s.split(separator: " ") {
      let w = String(word)
      if !stopwords.contains(w) { set.insert(w) }
    }
    return set
  }

  // ===========================================================
  // MARK: - Alternate Queries
  // ===========================================================

  private static func alternateQueries(for q: String) -> [String] {
    var alts: Set<String> = [q]

    // Drop *all* stopwords once
    let noStops = q.split(separator: " ")
      .map(String.init)
      .filter { !stopwords.contains($0) }
      .joined(separator: " ")
    if !noStops.isEmpty { alts.insert(noStops) }

    // Handle US/UK variants ("office" → try "office us", "office uk")
    if q.contains("office") {
      alts.insert(q + " us")
      alts.insert(q + " uk")
    }

    return Array(alts)
  }

  // ===========================================================
  // MARK: - Scoring helpers (unchanged, but tuned)
  // ===========================================================

  private static func jaccardScore(a: Set<String>, b: Set<String>) -> Int {
    if a.isEmpty || b.isEmpty { return 0 }
    let inter = a.intersection(b).count
    let uni = a.union(b).count
    return Int((Double(inter) / Double(max(1, uni))) * 100.0)
  }

  private static func containsWord(in haystack: String, needle: String) -> Bool {
    haystack.split(separator: " ").contains { $0 == Substring(needle) }
  }

  private static func hasWordPrefix(in haystack: String, needle: String) -> Bool {
    haystack.split(separator: " ").contains { $0.hasPrefix(needle) }
  }

  private static func cappedEditDistance(_ a: String, _ b: String, maxDistance: Int) -> Int {
    let aChars = Array(a), bChars = Array(b)
    let n = aChars.count, m = bChars.count
    if abs(n - m) > maxDistance { return maxDistance + 1 }
    if n == 0 { return min(m, maxDistance + 1) }
    if m == 0 { return min(n, maxDistance + 1) }

    let band = maxDistance, INF = maxDistance + 1
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
        let del = prev[j] + 1, ins = curr[j - 1] + 1, sub = prev[j - 1] + cost
        var v = min(del, min(ins, sub))
        curr[j] = v
        if v < rowMin { rowMin = v }
      }
      if rowMin > maxDistance { return maxDistance + 1 }
      swap(&prev, &curr)
    }
    return min(prev[m], maxDistance + 1)
  }

  private static func extractYear(_ s: String) -> Int? {
    let matches = s.split(separator: " ").compactMap { Int($0) }
    return matches.first { (1900...2100).contains($0) }
  }

  private static func scoreFromPopularity(_ item: TitleItem) -> Int {
    guard let votes = item.tmdbVoteCount, votes > 0 else { return 0 }
    let v = log(Double(votes))
    return max(0, min(20, Int(4.5 * v - 9.0)))
  }
}
