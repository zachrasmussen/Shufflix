//
//  Constants.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/24/25.
//

import Foundation

enum Constants {

    // MARK: - App (env tag for a single Supabase project)
    /// Reads `APP_ENV` from Info.plist and normalizes it to "prod" or "staging".
    /// Use this to tag DB rows (e.g., `app_env = Constants.App.env`) and to filter reads.
    enum App {
        /// Raw value from Info.plist (lowercased, trimmed). Defaults to "prod" if missing/invalid.
        private static let raw: String = {
            let plistValue = Bundle.main.object(forInfoDictionaryKey: "APP_ENV") as? String
            let envOverride = ProcessInfo.processInfo.environment["APP_ENV"]
            let raw = (envOverride?.isEmpty == false ? envOverride : plistValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return raw
        }()

        /// Normalized environment tag you should persist to the DB.
        static let env: String = {
            switch raw {
            case "staging": return "staging"
            case "prod", "production": return "prod"
            default:
                #if DEBUG
                print("⚠️ APP_ENV '\(raw)' not recognized. Defaulting to 'prod'.")
                #endif
                return "prod"
            }
        }()

        static var isStaging: Bool { env == "staging" }
        static var isProd: Bool    { env == "prod" }
    }

    // MARK: - Supabase
    enum Supabase {
        /// Project base URL (e.g., https://xyzcompany.supabase.co).
        /// Read from Info.plist `SUPABASE_URL`. Allows an env override for tests.
        static let url: String = {
            let plistValue = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
            let envOverride = ProcessInfo.processInfo.environment["SUPABASE_URL"]
            let raw = (envOverride?.isEmpty == false ? envOverride : plistValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !raw.isEmpty else {
                #if DEBUG
                fatalError("❌ Missing SUPABASE_URL in Info.plist (or env). Set it per scheme.")
                #else
                return "" // release: fail gracefully; client init will guard against empty URL
                #endif
            }
            return raw
        }()

        /// Anonymous public key. Read from Info.plist `SUPABASE_ANON_KEY`.
        static let anonKey: String = {
            let plistValue = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
            let envOverride = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
            let raw = (envOverride?.isEmpty == false ? envOverride : plistValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !raw.isEmpty else {
                #if DEBUG
                fatalError("❌ Missing SUPABASE_ANON_KEY in Info.plist (or env). Set it per scheme.")
                #else
                return "" // release: fail gracefully; network calls will no-op if misconfigured
                #endif
            }
            return raw
        }()
    }

    // MARK: - TMDB
    enum TMDB {
        /// v3 base API URL
        static let baseURL = URL(string: "https://api.themoviedb.org/3")!

        /// API key: must be provided in Info.plist under `TMDB_API_KEY`.
        /// In Debug builds, we `fatalError` if missing to catch misconfigurations early.
        /// In Release builds, we fail gracefully (empty string = invalid key).
        static let apiKey: String = {
            // Prefer Info.plist; allow an env override for unit/UI tests if present.
            let plistValue = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
            let envOverride = ProcessInfo.processInfo.environment["TMDB_API_KEY"]
            let raw = (envOverride?.isEmpty == false ? envOverride : plistValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !raw.isEmpty else {
                #if DEBUG
                fatalError("❌ Missing TMDB_API_KEY in Info.plist (or env). Add your TMDB key before running.")
                #else
                return "" // release: calls will fail safely if misconfigured
                #endif
            }
            return raw
        }()

        /// Default language in BCP-47 (e.g., "en-US").
        /// Uses the first preferred language if valid; else synthesizes from current Locale; falls back to "en-US".
        static let defaultLanguage: String = {
            if let first = Locale.preferredLanguages.first, !first.isEmpty {
                return normalizeBCP47(first)
            }
            let loc = Locale.current
            let lang = loc.language.languageCode?.identifier ?? "en"
            let region = loc.region?.identifier ?? "US"
            return "\(lang)-\(region)".replacingOccurrences(of: "_", with: "-")
        }()

        /// Default region: current device region, fallback to "US".
        static let defaultRegion: String = {
            Locale.current.region?.identifier ?? "US"
        }()

        /// Normalizes odd forms like "en_US" → "en-US". Keeps it simple (no script subtags).
        private static func normalizeBCP47(_ tag: String) -> String {
            if tag.contains("-") { return tag }
            if tag.contains("_") { return tag.replacingOccurrences(of: "_", with: "-") }
            let lang = tag
            let region = Locale.current.region?.identifier ?? "US"
            return "\(lang)-\(region)"
        }
    }

    // MARK: - Images
    /// Base image root (no size segment). Use helpers below to build full URLs.
    private static let imageRoot = URL(string: "https://image.tmdb.org/t/p")!

    enum ImageSize: String {
        // Posters
        case w92, w154, w185, w342, w500, w780
        // Backdrops / Stills
        case w1280
        // Original full-size
        case original

        // Semantic defaults
        static let posterDefault: ImageSize = .w500
        static let backdropDefault: ImageSize = .w780
    }

    /// Build a poster/backdrop URL safely.
    /// - Parameters:
    ///   - path: TMDB file path starting with `/` (e.g. `/abc123.jpg`) **or** a full URL (returned as-is).
    ///   - size: one of the supported sizes (default `.w500`)
    /// - Returns: URL or nil if `path` is empty or “null”
    @inlinable
    static func imageURL(path: String?, size: ImageSize = .posterDefault) -> URL? {
        guard var raw = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.lowercased() != "null" else { return nil }

        // Pass through if already an absolute URL
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }

        // Ensure it does not double-slash when joining
        if raw.hasPrefix("/") {
            raw.removeFirst()
        }

        // Percent-encode each path segment defensively
        let encoded = raw.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")

        var url = imageRoot
            .appendingPathComponent(size.rawValue, isDirectory: false)
            .appendingPathComponent(encoded, isDirectory: false)

        // Just in case TMDB ever returns stray double slashes
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.path = comps.path.replacingOccurrences(of: "//", with: "/")
            url = comps.url ?? url
        }
        return url
    }

    // MARK: - Genres
    /// TMDB GenreId -> Name
    static let genreMap: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary",
        18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Sci-Fi", 10770: "TV Movie", 53: "Thriller",
        10752: "War", 37: "Western"
    ]

    /// Name -> TMDB GenreId
    static let reverseGenreMap: [String: Int] = {
        Dictionary(uniqueKeysWithValues: genreMap.map { ($1, $0) })
    }()

    /// Convenience lookup helpers
    @inlinable static func genreName(for id: Int) -> String? { genreMap[id] }
    @inlinable static func genreID(for name: String) -> Int? { reverseGenreMap[name] }
}
