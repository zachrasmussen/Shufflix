//
//  TMDBService.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Restored: 2025-10-02 (static API with internal actor cache)
//

import Foundation

enum TMDBService {
    // MARK: - Infra

    private static let base = URL(string: "https://api.themoviedb.org/3")!

    // Keep a tuned session (ephemeral is fine since TMDB supports HTTP caching headers too)
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        // Respect OS proxy / connectivity; no extra headers here (set per-request)
        return URLSession(configuration: cfg)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    // MARK: - Cache (actor = thread-safe, no manual locking)

    private actor Cache {
        var providerCache = [String: [ProviderLink]]()
        var castCache     = [String: [CastMember]]()
        var detailsCache  = [String: String]()
        var videosCache   = [String: [Video]]()

        func providers(for key: String) -> [ProviderLink]? { providerCache[key] }
        func setProviders(_ v: [ProviderLink], for key: String) { providerCache[key] = v }

        func cast(for key: String) -> [CastMember]? { castCache[key] }
        func setCast(_ v: [CastMember], for key: String) { castCache[key] = v }

        func details(for key: String) -> String? { detailsCache[key] }
        func setDetails(_ v: String, for key: String) { detailsCache[key] = v }

        func videos(for key: String) -> [Video]? { videosCache[key] }
        func setVideos(_ v: [Video], for key: String) { videosCache[key] = v }

        func clearAll() {
            providerCache.removeAll(keepingCapacity: false)
            castCache.removeAll(keepingCapacity: false)
            detailsCache.removeAll(keepingCapacity: false)
            videosCache.removeAll(keepingCapacity: false)
        }
    }
    private static let cache = Cache()

    // MARK: - HTTP

    private static func components(_ path: String, _ items: [URLQueryItem] = []) -> URLComponents {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var query = items
        query.append(contentsOf: [
            URLQueryItem(name: "api_key", value: Constants.TMDB.apiKey),
            URLQueryItem(name: "language", value: Constants.TMDB.defaultLanguage)
        ])
        comps.queryItems = query
        return comps
    }

    private struct TMDBErrorResponse: Decodable, Error {
        let status_message: String?
        let status_code: Int?
    }

    /// Minimal retry (2 tries) with jitter for network/5xx; avoids over-retrying 4xx/user errors.
    private static func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let url = components(path, query).url!

        var lastError: Error?
        for _ in 0..<2 {
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue(Constants.TMDB.defaultLanguage, forHTTPHeaderField: "Accept-Language")

                let (data, resp) = try await session.data(for: req)

                if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                    if let err = try? decoder.decode(TMDBErrorResponse.self, from: data) {
                        throw NSError(domain: "TMDB", code: http.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: err.status_message ?? "TMDB error \(http.statusCode)"
                        ])
                    }
                    throw NSError(domain: "TMDB", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from TMDB"
                    ])
                }

                return try decoder.decode(T.self, from: data)
            } catch {
                lastError = error
                // Retry only on transient conditions
                if let urlErr = error as? URLError {
                    switch urlErr.code {
                    case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
                        // jitter 120–240ms
                        try? await Task.sleep(nanoseconds: 120_000_000 + UInt64(Int.random(in: 0...120)) * 1_000_000)
                        continue
                    default:
                        throw error
                    }
                }
                // If it's an HTTP error, we already threw above; otherwise just propagate
                break
            }
        }
        throw lastError ?? NSError(domain: "TMDB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown TMDB error"])
    }

    // MARK: - DTOs

    struct DiscoverResult: Decodable { let results: [Media] }

    struct Media: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let overview: String
        let poster_path: String?
        let release_date: String?
        let first_air_date: String?
        let media_type: String?
        let genre_ids: [Int]?
        let vote_average: Double?
        let vote_count: Int?
    }

    struct ProviderEnvelope: Decodable { let results: [String: RegionProviders] }
    struct RegionProviders: Decodable { let flatrate: [Provider]? }
    struct Provider: Decodable {
        let provider_id: Int
        let provider_name: String
        let logo_path: String?
    }

    struct VideosResponse: Decodable { let results: [Video] }
    struct Video: Decodable {
        let key: String
        let site: String    // "YouTube", "Vimeo", etc.
        let type: String    // "Trailer", "Teaser", etc.
        let official: Bool?
        let name: String
    }

    // For movies
    struct ReleaseDatesResponse: Decodable {
        struct Result: Decodable {
            let iso_3166_1: String
            let release_dates: [ReleaseDate]
        }
        struct ReleaseDate: Decodable { let certification: String }
        let results: [Result]
    }

    // For TV
    struct ContentRatingsResponse: Decodable {
        struct Result: Decodable {
            let iso_3166_1: String
            let rating: String
        }
        let results: [Result]
    }

    struct CreditsResponse: Decodable { let cast: [CastPerson] }
    struct CastPerson: Decodable { let name: String; let character: String? }
    struct CastMember: Hashable { let name: String; let character: String? }

    // MARK: - Provider Brand Normalization

    private static func canonicalizeProviderName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip qualifiers/parentheticals/“via …”
        let regexes: [NSRegularExpression] = [
            // suffix descriptors
            try! NSRegularExpression(pattern: #"(?i)\s+(with\s+ads|basic\s+with\s+ads|standard|basic|premium|uhd|4k|hd|originals?|channel|channels|add-?on|subscription|trial)\s*$"#),
            // via/on/through phrases
            try! NSRegularExpression(pattern: #"(?i)\s+(on|via|through)\s+.*$"#),
            // parentheticals
            try! NSRegularExpression(pattern: #"(?i)\s*\((ads?|via.*|channel|premium|originals?)\)\s*$"#)
        ]
        for r in regexes {
            s = r.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }

        let lower = s.lowercased()
        if lower.contains("paramount") { return "Paramount+" }
        if lower.contains("hbo max") || lower == "max" || lower.contains("max") { return "Max" }
        if lower.contains("prime video") || lower.contains("amazon") { return "Prime Video" }
        if lower.contains("apple tv+") || lower.contains("apple tv plus") { return "Apple TV+" }
        if lower.contains("disney") { return "Disney+" }
        if lower.contains("peacock") { return "Peacock" }
        if lower.contains("hulu") { return "Hulu" }
        if lower.contains("netflix") { return "Netflix" }
        if lower.contains("starz") { return "STARZ" }
        if lower.contains("showtime") { return "Showtime" }
        if lower.contains("tubi") { return "Tubi" }
        if lower.contains("pluto") { return "Pluto TV" }
        if lower.contains("youtube") { return "YouTube" }

        s = collapseSpaces(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Endpoints

    static func trending(window: String = "week", page: Int = 1) async throws -> [Media] {
        let res: DiscoverResult = try await get("trending/all/\(window)", query: [
            URLQueryItem(name: "page", value: String(page))
        ])
        return res.results
    }

    static func popular(_ type: MediaType, page: Int = 1) async throws -> [Media] {
        let res: DiscoverResult = try await get("\(type.rawValue)/popular", query: [
            URLQueryItem(name: "page", value: String(page))
        ])
        return res.results
    }

    static func topRated(_ type: MediaType, page: Int = 1) async throws -> [Media] {
        let res: DiscoverResult = try await get("\(type.rawValue)/top_rated", query: [
            URLQueryItem(name: "page", value: String(page))
        ])
        return res.results
    }

    static func discover(
        _ type: MediaType,
        page: Int = 1,
        genres: [Int]? = nil,
        watchRegion: String = Constants.TMDB.defaultRegion
    ) async throws -> [Media] {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "with_watch_monetization_types", value: "flatrate|free|ads|rent|buy"),
            URLQueryItem(name: "watch_region", value: watchRegion),
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "vote_count.gte", value: "100")
        ]
        if let genres, !genres.isEmpty {
            q.append(URLQueryItem(name: "with_genres", value: genres.map(String.init).joined(separator: ",")))
        }
        let res: DiscoverResult = try await get("discover/\(type.rawValue)", query: q)
        return res.results
    }

    static func searchMulti(query: String, page: Int = 1) async throws -> [Media] {
        let res: DiscoverResult = try await get("search/multi", query: [
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page))
        ])
        return res.results
    }

    static func searchTV(query: String, page: Int = 1) async throws -> [Media] {
        let res: DiscoverResult = try await get("search/tv", query: [
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page))
        ])
        return res.results
    }

    static func searchMovie(query: String, page: Int = 1, region: String = Constants.TMDB.defaultRegion) async throws -> [Media] {
        let res: DiscoverResult = try await get("search/movie", query: [
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "region", value: region)
        ])
        return res.results
    }

    // Providers (cached)
    static func watchProviders(for id: Int, mediaType: MediaType) async throws -> [ProviderLink] {
        let key = "prov:\(mediaType.rawValue)#\(id)"
        if let cached = await cache.providers(for: key) {
            return cached
        }

        let env: ProviderEnvelope = try await get("\(mediaType.rawValue)/\(id)/watch/providers")
        let us = env.results[Constants.TMDB.defaultRegion]?.flatrate ?? []

        var seenIDs = Set<Int>()
        var links: [ProviderLink] = []
        links.reserveCapacity(us.count)

        for p in us {
            guard seenIDs.insert(p.provider_id).inserted else { continue }

            let brand = canonicalizeProviderName(p.provider_name)
            guard !brand.isEmpty else { continue }

            let logo = Constants.imageURL(path: p.logo_path, size: .w342)
            let q = brand.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? brand
            let url = URL(string: "https://www.google.com/search?q=\(q)")!

            links.append(ProviderLink(name: brand, url: url, logoURL: logo))
        }

        let sorted = links.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        await cache.setProviders(sorted, for: key)
        return sorted
    }

    // Credits (cached)
    static func fetchCast(for id: Int, mediaType: MediaType) async throws -> [CastMember] {
        let key = "cast:\(mediaType.rawValue)#\(id)"
        if let cached = await cache.cast(for: key) {
            return cached
        }

        let credits: CreditsResponse = try await get("\(mediaType.rawValue)/\(id)/credits")
        let mapped = credits.cast.map { CastMember(name: $0.name, character: $0.character) }
        await cache.setCast(mapped, for: key)
        return mapped
    }

    // Similar
    static func fetchSimilar(for id: Int, mediaType: MediaType) async throws -> [TitleItem] {
        let res: DiscoverResult = try await get("\(mediaType.rawValue)/\(id)/similar", query: [
            URLQueryItem(name: "page", value: "1")
        ])
        return await mapToTitleItems(res.results)
    }

    // Details overview (cached, used for backfill)
    static func fetchDetailsOverview(for id: Int, mediaType: MediaType) async throws -> String {
        let key = "details:\(mediaType.rawValue)#\(id)"
        if let cached = await cache.details(for: key) {
            return cached
        }
        struct Details: Decodable { let overview: String? }
        let details: Details = try await get("\(mediaType.rawValue)/\(id)")
        let ov = details.overview ?? ""
        await cache.setDetails(ov, for: key)
        return ov
    }

    // Videos (cached)
    static func fetchVideos(for id: Int, mediaType: MediaType) async throws -> [Video] {
        let key = "vid:\(mediaType.rawValue)#\(id)"
        if let cached = await cache.videos(for: key) {
            return cached
        }
        let res: VideosResponse = try await get("\(mediaType.rawValue)/\(id)/videos")
        await cache.setVideos(res.results, for: key)
        return res.results
    }

    /// Pick the "best" trailer and return an embeddable URL if possible.
    static func bestTrailerURL(from vids: [Video]) -> URL? {
        let preferred: Video? =
            vids.first(where: { $0.site.caseInsensitiveCompare("YouTube") == .orderedSame &&
                                $0.type.caseInsensitiveCompare("Trailer") == .orderedSame &&
                                ($0.official ?? false) }) ??
            vids.first(where: { $0.site.caseInsensitiveCompare("YouTube") == .orderedSame &&
                                $0.type.caseInsensitiveCompare("Trailer") == .orderedSame }) ??
            vids.first(where: { $0.site.caseInsensitiveCompare("YouTube") == .orderedSame &&
                                $0.type.caseInsensitiveCompare("Teaser") == .orderedSame })
        guard let key = preferred?.key else { return nil }
        return URL(string: "https://www.youtube.com/embed/\(key)?playsinline=1&rel=0")
    }

    // MARK: - Mapping

    /// Map TMDB `Media` results to your `TitleItem` model.
    /// Fetches providers with a **capped concurrency** to reduce API burst/load.
    static func mapToTitleItems(_ media: [Media]) async -> [TitleItem] {
        let slice = Array(media.prefix(60))
        let maxConcurrentProviderCalls = 8

        var items: [TitleItem] = []
        items.reserveCapacity(slice.count)

        await withTaskGroup(of: TitleItem?.self) { group in
            // simple FIFO cap: add, and when at cap, await one before adding next
            var inFlight = 0

            for m in slice {
                if inFlight >= maxConcurrentProviderCalls {
                    if let r = await group.next(), let ti = r { items.append(ti) }
                    inFlight -= 1
                }

                group.addTask {
                    let type: MediaType = inferType(from: m)
                    let name = m.title ?? m.name ?? "Untitled"
                    let year = (m.release_date ?? m.first_air_date)?.prefix(4).description ?? ""
                    let poster = Constants.imageURL(path: m.poster_path, size: .w500)
                    let genreNames = (m.genre_ids ?? []).compactMap { Constants.genreMap[$0] }
                    let providers = (try? await watchProviders(for: m.id, mediaType: type)) ?? []
                    return TitleItem(
                        id: m.id,
                        mediaType: type,
                        name: name,
                        year: year,
                        overview: m.overview,
                        posterURL: poster,
                        genres: genreNames,
                        providers: providers,
                        tmdbRating: m.vote_average,
                        tmdbVoteCount: m.vote_count
                    )
                }
                inFlight += 1
            }

            while let r = await group.next() {
                if let ti = r { items.append(ti) }
            }
        }

        return items
    }

    // MARK: - Certifications

    static func fetchCertification(for id: Int, mediaType: MediaType) async throws -> String? {
        switch mediaType {
        case .movie:
            let decoded: ReleaseDatesResponse = try await get("movie/\(id)/release_dates")
            if let us = decoded.results.first(where: { $0.iso_3166_1 == Constants.TMDB.defaultRegion }),
               let cert = us.release_dates.first?.certification, !cert.isEmpty {
                return cert
            }
        case .tv, .unknown:
            let decoded: ContentRatingsResponse = try await get("tv/\(id)/content_ratings")
            if let us = decoded.results.first(where: { $0.iso_3166_1 == Constants.TMDB.defaultRegion }),
               !us.rating.isEmpty {
                return us.rating
            }
        }
        return nil
    }

    // MARK: - Improved Search (recall-first + exact-match rescue)

    enum MediaTypeFilter { case all, movie, tv }

    static func searchTitles(
        query: String,
        type: MediaTypeFilter = .all,
        pageLimit: Int = 3,
        region: String = Constants.TMDB.defaultRegion
    ) async throws -> [TitleItem] {

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var buckets: [[Media]] = []

        switch type {
        case .all:
            var acc: [Media] = []
            for page in 1...pageLimit {
                acc += try await searchMulti(query: trimmed, page: page)
            }
            buckets.append(acc)
            // cheap backups to improve recall for classics
            buckets.append(try await searchTV(query: trimmed, page: 1))
            buckets.append(try await searchMovie(query: trimmed, page: 1, region: region))

        case .tv:
            var acc: [Media] = []
            for page in 1...pageLimit { acc += try await searchTV(query: trimmed, page: page) }
            buckets.append(acc)

        case .movie:
            var acc: [Media] = []
            for page in 1...pageLimit { acc += try await searchMovie(query: trimmed, page: page, region: region) }
            buckets.append(acc)
        }

        // Merge & de-dupe
        var seen = Set<String>()
        var merged: [Media] = []
        merged.reserveCapacity(120)
        for arr in buckets {
            for m in arr {
                let mt = inferType(from: m) == .tv ? "tv" : "movie"
                let key = "\(m.id)#\(mt)"
                if seen.insert(key).inserted { merged.append(m) }
            }
        }

        // Quick map (no provider IO for speed)
        let quickItems: [TitleItem] = mapMediaToTitleItemsQuick(merged)

        // Fuzzy rank + exact/starts-with rescue
        var ranked = SearchRanker.rank(query: trimmed, items: quickItems, limit: 80)

        if ranked.isEmpty || ranked.count < 3 {
            let qNorm = normalize(trimmed)
            func rescueScore(_ t: TitleItem) -> Int {
                let n = normalize(t.name)
                if n == qNorm { return 100 }
                if n.hasPrefix(qNorm) { return 90 }
                if n.contains(qNorm) { return 80 }
                return 0
            }
            let boosted = quickItems
                .map { ($0, rescueScore($0)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }

            var keys = Set(ranked.map { "\($0.id)#\($0.mediaType.rawValue)" })
            for b in boosted {
                let k = "\(b.id)#\(b.mediaType.rawValue)"
                if keys.insert(k).inserted { ranked.insert(b, at: 0) }
            }
        }

        return ranked
    }

    // Lightweight mapper for search (no provider round-trips)
    private static func mapMediaToTitleItemsQuick(_ media: [Media]) -> [TitleItem] {
        var out: [TitleItem] = []
        out.reserveCapacity(min(media.count, 80))

        for m in media.prefix(80) {
            let type: MediaType = inferType(from: m)
            let year = (m.release_date ?? m.first_air_date)?.prefix(4).description ?? ""
            let poster = Constants.imageURL(path: m.poster_path, size: .w500)
            let genreNames = (m.genre_ids ?? []).compactMap { Constants.genreMap[$0] }

            out.append(TitleItem(
                id: m.id,
                mediaType: type,
                name: m.title ?? m.name ?? "Untitled",
                year: year,
                overview: m.overview,
                posterURL: poster,
                genres: genreNames,
                providers: [], // fast path: provider fetch deferred
                tmdbRating: m.vote_average,
                tmdbVoteCount: m.vote_count
            ))
        }
        return out
    }

    // MARK: - Helpers

    private static func inferType(from m: Media) -> MediaType {
        if m.media_type == "tv" { return .tv }
        if m.media_type == "movie" { return .movie }
        // Heuristic: multi often omits media_type—fall back on known fields
        if m.first_air_date != nil && m.title == nil { return .tv }
        return .movie
    }

    /// Collapse multiple whitespace runs into a single space.
    private static func collapseSpaces(_ s: String) -> String {
        let re = try! NSRegularExpression(pattern: #" {2,}"#)
        return re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    /// Lowercased, diacritic-insensitive, alnum + spaces only, collapsed spaces.
    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var chars = [Character](); chars.reserveCapacity(folded.count)
        var lastWasSpace = false
        for u in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) {
                chars.append(Character(u))
                lastWasSpace = false
            } else if !lastWasSpace {
                chars.append(" ")
                lastWasSpace = true
            }
        }
        if chars.last == " " { chars.removeLast() }
        return collapseSpaces(String(chars))
    }

    // Optional utility to clear in-memory caches (e.g., on memory warning)
    static func clearCaches() {
        Task { await cache.clearAll() }
    }
}
