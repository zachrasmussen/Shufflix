//
//  StreamingLinker.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import UIKit

/// StreamingLinker centralizes provider deep-linking logic.
/// Prioritizes fast native app opens, then universal links, then JustWatch/Google fallbacks.
///
/// NOTE: Keys in `apps` must match names from `TMDBService.canonicalizeProviderName(_:)`.
/// Add new schemes to Info.plist → LSApplicationQueriesSchemes.
@MainActor
struct StreamingLinker {

  // MARK: - App Spec

  struct AppSpec {
    let displayName: String
    /// Candidate custom URL schemes to open the native app directly (first installed wins).
    let schemeCandidates: [URL]
    /// Universal link root (opens the app if associated, else the web).
    let universalURL: URL?
    /// Optional builder for provider-specific search/deep link.
    let buildSearchURL: ((String, Int?) -> URL?)?

    init(
      displayName: String,
      schemeCandidates: [URL] = [],
      universalURL: URL?,
      buildSearchURL: ((String, Int?) -> URL?)? = nil
    ) {
      self.displayName = displayName
      self.schemeCandidates = schemeCandidates
      self.universalURL = universalURL
      self.buildSearchURL = buildSearchURL
    }
  }

  // MARK: - Catalog

  static let apps: [String: AppSpec] = [
    "Netflix": .init(
      displayName: "Netflix",
      schemeCandidates: [url("nflx://www.netflix.com/"), url("nflx://")],
      universalURL: url("https://www.netflix.com"),
      buildSearchURL: { t, y in queryURL("https://www.netflix.com/search", q: titleWithYear(t, y)) }
    ),
    "Hulu": .init(
      displayName: "Hulu",
      schemeCandidates: [url("hulu://")],
      universalURL: url("https://www.hulu.com"),
      buildSearchURL: { t, y in queryURL("https://www.hulu.com/search", q: titleWithYear(t, y)) }
    ),
    "Disney+": .init(
      displayName: "Disney+",
      schemeCandidates: [url("disneyplus://")],
      universalURL: url("https://www.disneyplus.com"),
      buildSearchURL: { t, _ in
        guard var c = URLComponents(string: "https://www.disneyplus.com/search/") else { return nil }
        c.path.append(safePath(normalize(t)))
        return c.url
      }
    ),
    "Prime Video": .init(
      displayName: "Prime Video",
      schemeCandidates: [url("primevideo://")],
      universalURL: url("https://www.primevideo.com"),
      buildSearchURL: { t, y in queryURL("https://www.primevideo.com/search", q: titleWithYear(t, y)) }
    ),
    "Apple TV+": .init(
      displayName: "Apple TV+",
      schemeCandidates: [url("tv://"), url("videos://")],
      universalURL: url("https://tv.apple.com"),
      buildSearchURL: { t, y in queryURL("https://tv.apple.com/search", q: titleWithYear(t, y)) }
    ),
    "Max": .init(
      displayName: "Max",
      schemeCandidates: [url("hbomax://")],
      universalURL: url("https://play.max.com"),
      buildSearchURL: { t, y in queryURL("https://play.max.com/search", q: titleWithYear(t, y)) }
    ),
    "Peacock": .init(
      displayName: "Peacock",
      schemeCandidates: [url("peacock://")],
      universalURL: url("https://www.peacocktv.com"),
      buildSearchURL: { t, y in queryURL("https://www.peacocktv.com/search", q: titleWithYear(t, y)) }
    ),
    "Paramount+": .init(
      displayName: "Paramount+",
      schemeCandidates: [url("paramountplus://")],
      universalURL: url("https://www.paramountplus.com"),
      buildSearchURL: { t, y in queryURL("https://www.paramountplus.com/s/search/", q: titleWithYear(t, y), key: "q") }
    ),
    "YouTube": .init(
      displayName: "YouTube",
      schemeCandidates: [url("youtube://")],
      universalURL: url("https://www.youtube.com"),
      buildSearchURL: { t, y in queryURL("https://www.youtube.com/results", q: titleWithYear(t, y)) }
    ),
    "Crunchyroll": .init(
      displayName: "Crunchyroll",
      schemeCandidates: [url("crunchyroll://")],
      universalURL: url("https://www.crunchyroll.com"),
      buildSearchURL: { t, y in queryURL("https://www.crunchyroll.com/search", q: titleWithYear(t, y), key: "qt") }
    ),
    "STARZ": .init(
      displayName: "STARZ",
      schemeCandidates: [url("starz://")],
      universalURL: url("https://www.starz.com"),
      buildSearchURL: { t, y in queryURL("https://www.starz.com/us/en/search", q: titleWithYear(t, y)) }
    ),
    "Showtime": .init(
      displayName: "Showtime",
      schemeCandidates: [url("showtimeanytime://")],
      universalURL: url("https://www.showtime.com"),
      buildSearchURL: { t, y in queryURL("https://www.showtime.com/search", q: titleWithYear(t, y)) }
    ),
    "Tubi": .init(
      displayName: "Tubi",
      schemeCandidates: [url("tubi://")],
      universalURL: url("https://tubitv.com"),
      buildSearchURL: { t, _ in
        guard var c = URLComponents(string: "https://tubitv.com/search/") else { return nil }
        c.path.append(safePath(normalize(t)))
        return c.url
      }
    ),
    "Pluto TV": .init(
      displayName: "Pluto TV",
      schemeCandidates: [url("pluto-tv://"), url("plutotv://")],
      universalURL: url("https://pluto.tv"),
      buildSearchURL: { t, y in queryURL("https://pluto.tv/en/search", q: titleWithYear(t, y)) }
    )
  ]

  // MARK: - Public

  /// Opens a provider app or website for the given title.
  /// Returns `true` if something was opened, else `false` (after fallbacks).
  @discardableResult
  static func open(providerName: String, title: String, year: Int? = nil) -> Bool {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else { return false }

    guard let spec = apps[providerName] else {
      return openFallbackSearch(title: trimmedTitle, providerName: providerName, year: year)
    }

    // 1) Try native schemes
    for scheme in dedup(spec.schemeCandidates) {
      if UIApplication.shared.canOpenURL(scheme) {
        UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
        return true
      }
    }

    // 2) Try provider-specific deep link, else universal root
    if let deep = spec.buildSearchURL?(trimmedTitle, year) ?? spec.universalURL {
      UIApplication.shared.open(deep, options: [:], completionHandler: nil)
      return true
    }

    // 3) Fallback → JustWatch → Google
    return openFallbackSearch(title: trimmedTitle, providerName: providerName, year: year)
  }

  // MARK: - Fallbacks

  private static func openFallbackSearch(title: String, providerName: String, year: Int?) -> Bool {
    if let jw = queryURL("https://www.justwatch.com/us/search", q: titleWithYear(title, year)) {
      UIApplication.shared.open(jw, options: [:], completionHandler: nil)
      return true
    }
    let q = "watch \(titleWithYear(title, year)) \(providerName)"
    if let g = queryURL("https://www.google.com/search", q: q) {
      UIApplication.shared.open(g, options: [:], completionHandler: nil)
      return true
    }
    return false
  }

  // MARK: - URL Builders

  private static func queryURL(_ base: String, q query: String, key: String = "q") -> URL? {
    guard var c = URLComponents(string: base) else { return nil }
    let norm = normalize(query)
    var items = c.queryItems ?? []
    items.append(URLQueryItem(name: key, value: norm))
    c.queryItems = items
    return c.url
  }

  private static func normalize(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    return folded
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func safePath(_ s: String) -> String {
    s.split(separator: "/").map {
      $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
    }.joined(separator: "/")
  }

  private static func titleWithYear(_ title: String, _ year: Int?) -> String {
    guard let y = year else { return title }
    return "\(title) \(y)"
  }

  private static func dedup<T: Hashable>(_ arr: [T]) -> [T] {
    var seen = Set<T>()
    var out: [T] = []
    out.reserveCapacity(arr.count)
    for x in arr where seen.insert(x).inserted { out.append(x) }
    return out
  }

  private static func url(_ s: String) -> URL { URL(string: s)! }
}
