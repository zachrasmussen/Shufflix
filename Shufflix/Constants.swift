//
//  Constants.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/24/25.
//  Refactored: 2025-10-02
//

import Foundation
import os.log

// MARK: - Logger (debug-only noise; no-op in Release)
private enum Log {
    static func warn(_ message: @autoclosure () -> String) {
        #if DEBUG
        if #available(iOS 14.0, *) {
            os_log(.fault, "[Constants] %{public}@", message())
        } else {
            print("⚠️ [Constants] \(message())")
        }
        #endif
    }
}

// MARK: - Constants namespace
enum Constants {

    // MARK: - App (single Supabase project with env partition)
    /// Use `Constants.App.env` as the value persisted to DB in `app_env` column.
    enum App {
        @frozen enum Env: String {
            case prod = "prod"
            case staging = "staging"
        }

        /// Raw environment string from Process ENV or Info.plist (lowercased, trimmed).
        private static let raw: String = {
            let env = ProcessInfo.processInfo.environment["APP_ENV"]
                ?? (Bundle.main.object(forInfoDictionaryKey: "APP_ENV") as? String) ?? ""
            return env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }()

        /// Normalized environment tag to store alongside rows.
        static let env: String = {
            switch raw {
            case "staging": return Env.staging.rawValue
            case "prod", "production": return Env.prod.rawValue
            default:
                Log.warn("APP_ENV '\(raw)' not recognized. Defaulting to 'prod'.")
                return Env.prod.rawValue
            }
        }()

        static var isStaging: Bool { env == Env.staging.rawValue }
        static var isProd: Bool    { env == Env.prod.rawValue }
    }

    // MARK: - Supabase
    enum Supabase {
        /// Project base URL string (kept as String for backwards compatibility).
        static let url: String = {
            requiredPlistString(key: "SUPABASE_URL", debugLabel: "SUPABASE_URL")
        }()

        /// Anonymous public key.
        static let anonKey: String = {
            requiredPlistString(key: "SUPABASE_ANON_KEY", debugLabel: "SUPABASE_ANON_KEY")
        }()

        /// Convenience `URL` version of `url` if needed by callers.
        static var urlAsURL: URL? { URL(string: url) }
    }

    // MARK: - TMDB
    enum TMDB {
        /// v3 base API URL
        static let baseURL = URL(string: "https://api.themoviedb.org/3")!

        /// API key (Info.plist `TMDB_API_KEY`, with ENV override allowed).
        static let apiKey: String = {
            requiredPlistString(key: "TMDB_API_KEY", debugLabel: "TMDB_API_KEY")
        }()

        /// Default language in BCP-47 (e.g., "en-US").
        static let defaultLanguage: String = {
            // Prefer first preferred language; normalize to "ll-RR" when possible.
            if let first = Locale.preferredLanguages.first, !first.isEmpty {
                return normalizeBCP47(first)
            }
            let lang = Locale.current.language.languageCode?.identifier ?? "en"
            let region = Locale.current.region?.identifier ?? "US"
            return "\(lang)-\(region)"
        }()

        /// Default region (ISO 3166-1 alpha-2). Fallback "US".
        static let defaultRegion: String = Locale.current.region?.identifier ?? "US"

        /// Normalizes odd forms like "en_US" → "en-US". Keeps it simple (no script subtags).
        private static func normalizeBCP47(_ tag: String) -> String {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "en-US" }

            // Already looks like a BCP-47 tag
            if trimmed.contains("-") { return trimmed }

            // Convert underscore forms: en_US → en-US
            if trimmed.contains("_") { return trimmed.replacingOccurrences(of: "_", with: "-") }

            // Only language provided; append current region
            let region = Locale.current.region?.identifier ?? "US"
            return "\(trimmed)-\(region)"
        }
    }

    // MARK: - Images
    private static let imageRoot = URL(string: "https://image.tmdb.org/t/p")!

    @frozen enum ImageSize: String {
        // Posters
        case w92, w154, w185, w342, w500, w780
        // Backdrops / Stills
        case w1280
        // Original full-size
        case original

        static let posterDefault: ImageSize = .w500
        static let backdropDefault: ImageSize = .w780
    }

    /// Build a poster/backdrop URL.
    /// - Parameters:
    ///   - path: TMDB file path starting with `/` (e.g. `/abc123.jpg`) or a full URL.
    ///   - size: desired TMDB rendition size (default `.w500`).
    /// - Returns: URL or `nil` if `path` is empty/`"null"`.
    @inlinable
    static func imageURL(path: String?, size: ImageSize = .posterDefault) -> URL? {
        guard var raw = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.lowercased() != "null" else { return nil }

        // Absolute URL passthrough
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }

        // Remove leading slash to avoid // when joining
        if raw.hasPrefix("/") { raw.removeFirst() }

        // Encode per path segment
        let encoded = raw.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")

        // Compose
        var url = imageRoot
            .appendingPathComponent(size.rawValue, isDirectory: false)
            .appendingPathComponent(encoded, isDirectory: false)

        // Defensive cleanup in case of accidental double slashes
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.path = comps.path.replacingOccurrences(of: "//", with: "/")
            url = comps.url ?? url
        }
        return url
    }

    // MARK: - Genres
    /// TMDB GenreId → Name (curated core set to keep UI tidy)
    static let genreMap: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary",
        18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Sci-Fi", 10770: "TV Movie", 53: "Thriller",
        10752: "War", 37: "Western"
    ]

    /// Case-insensitive Name → TMDB GenreId
    static let reverseGenreMap: [String: Int] = {
        Dictionary(uniqueKeysWithValues: genreMap.map { (name: $0.value.lowercased(), id: $0.key) })
    }()

    /// Convenience helpers
    @inlinable static func genreName(for id: Int) -> String? { genreMap[id] }
    @inlinable static func genreID(for name: String) -> Int? { reverseGenreMap[name.lowercased()] }
}

// MARK: - Private helpers

/// Reads a string from ENV or Info.plist (ENV wins), trims it, and enforces presence in Debug.
/// In Release, returns empty string on failure so callers can fail gracefully.
private func requiredPlistString(key: String, debugLabel: String) -> String {
    let env = ProcessInfo.processInfo.environment[key]
    let plist = Bundle.main.object(forInfoDictionaryKey: key) as? String
    let raw = (env?.isEmpty == false ? env : plist)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !raw.isEmpty else {
        #if DEBUG
        fatalError("❌ Missing \(debugLabel) in Info.plist or ENV. Configure per scheme.")
        #else
        Log.warn("\(debugLabel) missing; returning empty string for graceful failure in Release.")
        return ""
        #endif
    }
    return raw
}
