//
//  StreamingLinker.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Refactored: 2025-10-02
//

import Foundation
import UIKit

/// NOTE: Keys in `apps` must match names from `TMDBService.canonicalizeProviderName(_:)`,
/// e.g. "Paramount+", "Max", "Prime Video", "Apple TV+", "Disney+", "Hulu", "Netflix",
/// "STARZ", "Showtime", "Tubi", "Pluto TV", "YouTube", "Peacock", "Crunchyroll".
///
/// If you add more schemes, remember LSApplicationQueriesSchemes in Info.plist.
@MainActor
struct StreamingLinker {

    // MARK: - App Spec

    struct AppSpec {
        let displayName: String
        /// Candidate custom URL schemes to open the native app directly (first allowed + installed wins).
        let schemeCandidates: [URL]
        /// Universal link root (opens the app if associated; else website).
        let universalURL: URL?
        /// Optional builder for a provider-specific search/deep link when we know title/year.
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
            schemeCandidates: [
                URL(string: "nflx://www.netflix.com/")!,
                URL(string: "nflx://")!
            ],
            universalURL: URL(string: "https://www.netflix.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.netflix.com/search", q: titleWithYear(title, year)) }
        ),
        "Hulu": .init(
            displayName: "Hulu",
            schemeCandidates: [URL(string: "hulu://")!],
            universalURL: URL(string: "https://www.hulu.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.hulu.com/search", q: titleWithYear(title, year)) }
        ),
        "Disney+": .init(
            displayName: "Disney+",
            schemeCandidates: [URL(string: "disneyplus://")!],
            universalURL: URL(string: "https://www.disneyplus.com"),
            buildSearchURL: { title, _ in
                guard var c = URLComponents(string: "https://www.disneyplus.com/search/") else { return nil }
                c.path.append(contentsOf: safePath(normalize(title)))
                return c.url
            }
        ),
        "Prime Video": .init(
            displayName: "Prime Video",
            schemeCandidates: [URL(string: "primevideo://")!],
            universalURL: URL(string: "https://www.primevideo.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.primevideo.com/search", q: titleWithYear(title, year)) }
        ),
        "Apple TV+": .init(
            displayName: "Apple TV+",
            schemeCandidates: [
                URL(string: "tv://")!,
                URL(string: "videos://")!
            ],
            universalURL: URL(string: "https://tv.apple.com"),
            buildSearchURL: { title, year in queryURL(base: "https://tv.apple.com/search", q: titleWithYear(title, year)) }
        ),
        "Max": .init(
            displayName: "Max",
            schemeCandidates: [URL(string: "hbomax://")!],
            universalURL: URL(string: "https://play.max.com"),
            buildSearchURL: { title, year in queryURL(base: "https://play.max.com/search", q: titleWithYear(title, year)) }
        ),
        "Peacock": .init(
            displayName: "Peacock",
            schemeCandidates: [URL(string: "peacock://")!],
            universalURL: URL(string: "https://www.peacocktv.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.peacocktv.com/search", q: titleWithYear(title, year)) }
        ),
        "Paramount+": .init(
            displayName: "Paramount+",
            schemeCandidates: [URL(string: "paramountplus://")!],
            universalURL: URL(string: "https://www.paramountplus.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.paramountplus.com/s/search/", q: titleWithYear(title, year), key: "q") }
        ),
        "YouTube": .init(
            displayName: "YouTube",
            schemeCandidates: [URL(string: "youtube://")!],
            universalURL: URL(string: "https://www.youtube.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.youtube.com/results", q: titleWithYear(title, year)) }
        ),
        "Crunchyroll": .init(
            displayName: "Crunchyroll",
            schemeCandidates: [URL(string: "crunchyroll://")!],
            universalURL: URL(string: "https://www.crunchyroll.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.crunchyroll.com/search", q: titleWithYear(title, year), key: "qt") }
        ),
        "STARZ": .init(
            displayName: "STARZ",
            schemeCandidates: [URL(string: "starz://")!],
            universalURL: URL(string: "https://www.starz.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.starz.com/us/en/search", q: titleWithYear(title, year)) }
        ),
        "Showtime": .init(
            displayName: "Showtime",
            schemeCandidates: [URL(string: "showtimeanytime://")!],
            universalURL: URL(string: "https://www.showtime.com"),
            buildSearchURL: { title, year in queryURL(base: "https://www.showtime.com/search", q: titleWithYear(title, year)) }
        ),
        "Tubi": .init(
            displayName: "Tubi",
            schemeCandidates: [URL(string: "tubi://")!],
            universalURL: URL(string: "https://tubitv.com"),
            buildSearchURL: { title, _ in
                guard var c = URLComponents(string: "https://tubitv.com/search/") else { return nil }
                c.path.append(contentsOf: safePath(normalize(title)))
                return c.url
            }
        ),
        "Pluto TV": .init(
            displayName: "Pluto TV",
            schemeCandidates: [URL(string: "pluto-tv://")!, URL(string: "plutotv://")!],
            universalURL: URL(string: "https://pluto.tv"),
            buildSearchURL: { title, year in queryURL(base: "https://pluto.tv/en/search", q: titleWithYear(title, year)) }
        ),
    ]

    // MARK: - Public

    /// Opens a provider app or website for the given title.
    /// Returns `true` if something was opened, else `false` (after fallbacks).
    @discardableResult
    static func open(providerName: String, title: String, year: Int? = nil) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }

        // Unknown provider → rich fallback chain (JustWatch → Google)
        guard let spec = apps[providerName] else {
            return openFallbackSearch(title: trimmedTitle, providerName: providerName, year: year)
        }

        // 1) Try any allowed + installed app scheme (order matters)
        for scheme in dedup(spec.schemeCandidates) {
            if UIApplication.shared.canOpenURL(scheme) {
                UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
                return true
            }
        }

        // 2) Try provider-specific search URL (or universal root) to trigger associated app or web
        if let deep = spec.buildSearchURL?(trimmedTitle, year) ?? spec.universalURL {
            UIApplication.shared.open(deep, options: [:], completionHandler: nil)
            return true
        }

        // 3) Fallback → aggregator, then Google
        return openFallbackSearch(title: trimmedTitle, providerName: providerName, year: year)
    }

    // MARK: - Fallbacks

    @discardableResult
    private static func openFallbackSearch(title: String, providerName: String, year: Int?) -> Bool {
        // Prefer JustWatch (great for availability across providers)
        if let jw = queryURL(base: "https://www.justwatch.com/us/search", q: titleWithYear(title, year)) {
            UIApplication.shared.open(jw, options: [:], completionHandler: nil)
            return true
        }
        // Then Google with a provider bias
        let q = "watch \(titleWithYear(title, year)) \(providerName)"
        if let g = queryURL(base: "https://www.google.com/search", q: q) {
            UIApplication.shared.open(g, options: [:], completionHandler: nil)
            return true
        }
        return false
    }

    // MARK: - URL Builders

    /// Builds `...?q=<query>` (or custom key) with proper encoding.
    private static func queryURL(base: String, q query: String, key: String = "q") -> URL? {
        guard var c = URLComponents(string: base) else { return nil }
        let norm = normalize(query)
        var items = c.queryItems ?? []
        items.append(URLQueryItem(name: key, value: norm))
        c.queryItems = items
        return c.url
    }

    /// Normalizes a title/query: lowercase/diacritic-insensitive, single-spaces.
    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Safer path component appending (percent-encodes each segment).
    private static func safePath(_ s: String) -> String {
        s.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }

    /// Title with optional year appended (reduces false positives on many services).
    private static func titleWithYear(_ title: String, _ year: Int?) -> String {
        guard let y = year else { return title }
        return "\(title) \(y)"
    }

    /// Deduplicate while preserving order.
    private static func dedup<T: Hashable>(_ arr: [T]) -> [T] {
        var seen = Set<T>()
        var out: [T] = []
        out.reserveCapacity(arr.count)
        for x in arr where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
