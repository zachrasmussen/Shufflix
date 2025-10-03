//
//  Constants.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/24/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import os

// MARK: - Debug Log (no-ops in Release)
private enum Log {
    @inline(__always)
    private static var logger: Logger? {
        #if DEBUG
        if #available(iOS 14.0, *) {
            return Logger(subsystem: Bundle.main.bundleIdentifier ?? "Shufflix", category: "Constants")
        }
        #endif
        return nil
    }

    /// Synchronous warning. The autoclosure is evaluated immediately (does **not** escape).
    @inline(__always)
    static func warn(_ message: @autoclosure () -> String,
                     file: StaticString = #fileID,
                     line: UInt = #line) {
        #if DEBUG
        let msg = message() // evaluate now
        if let logger = logger {
            logger.error("[\(String(describing: file)):\(line)] \(msg, privacy: .public)")
        } else {
            print("⚠️ [\(file):\(line)] \(msg)")
        }
        #endif
    }

    /// If you *must* hop threads, evaluate the autoclosure **before** the async boundary.
    static func warnLater(_ message: @autoclosure () -> String,
                          file: StaticString = #fileID,
                          line: UInt = #line) {
        #if DEBUG
        let msg = message() // capture value now so the autoclosure does not escape
        DispatchQueue.global(qos: .utility).async {
            if let logger = logger {
                logger.error("[\(String(describing: file)):\(line)] \(msg, privacy: .public)")
            } else {
                print("⚠️ [\(file):\(line)] \(msg)")
            }
        }
        #endif
    }
}

// MARK: - Constants namespace
@frozen
enum Constants {

    // MARK: - Build channels / distribution info
    enum Build {
        /// True on TestFlight installs.
        static let isTestFlight: Bool = {
            #if targetEnvironment(simulator)
            return false
            #else
            // TestFlight builds have a receipt ending with "sandboxReceipt"
            let last = Bundle.main.appStoreReceiptURL?.lastPathComponent ?? ""
            return last == "sandboxReceipt"
            #endif
        }()

        /// True on App Store (not TestFlight, not Debug/AdHoc).
        static let isAppStore: Bool = {
            #if targetEnvironment(simulator)
            return false
            #else
            if isTestFlight { return false }
            // If a receipt exists and is not sandbox, assume App Store.
            return Bundle.main.appStoreReceiptURL != nil
            #endif
        }()
    }

    // MARK: - App (single Supabase project with env partition)
    /// Use `Constants.App.env` as the tag persisted to DB in `app_env`.
    enum App {
        @frozen enum Env: String { case prod, staging }

        /// Raw environment string from Process ENV or Info.plist (lowercased, trimmed).
        private static let raw: String = {
            let env = ProcessInfo.processInfo.environment["APP_ENV"]
                ?? (Bundle.main.object(forInfoDictionaryKey: "APP_ENV") as? String) ?? ""
            return env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }()

        /// Normalized environment tag to store alongside rows.
        static let env: String = {
            switch raw {
            case Env.staging.rawValue:
                return Env.staging.rawValue
            case "prod", "production":
                return Env.prod.rawValue
            case "": fallthrough
            default:
                Log.warn("APP_ENV '\(raw)' not recognized. Defaulting to 'prod'. Configure per scheme.")
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

        /// Convenience `URL` version of `url` if needed by callers (validated once).
        static let urlAsURL: URL? = {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let u = URL(string: trimmed) else {
                Log.warn("Invalid SUPABASE_URL '\(url)'")
                return nil
            }
            return u
        }()
    }

    // MARK: - TMDB
    enum TMDB {
        /// v3 base API URL
        static let baseURL = URL(string: "https://api.themoviedb.org/3")!

        /// API key (Info.plist `TMDB_API_KEY`, with ENV override allowed).
        static let apiKey: String = {
            requiredPlistString(key: "TMDB_API_KEY", debugLabel: "TMDB_API_KEY")
        }()

        /// Default language in canonical BCP-47 (e.g., "en-US").
        static let defaultLanguage: String = {
            if let first = Locale.preferredLanguages.first, !first.isEmpty {
                return canonicalBCP47(first)
            }
            return fallbackBCP47()
        }()

        /// Default region (ISO 3166-1 alpha-2). Fallback "US".
        static let defaultRegion: String = {
            (Locale.current.regionCode ?? Locale.current.region?.identifier ?? "US").uppercased()
        }()
    }

    // MARK: - Images
    private static let imageRoot = URL(string: "https://image.tmdb.org/t/p")!

    @frozen
    enum ImageSize: String {
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
    ///   - path: TMDB file path starting with `/` (e.g. `/abc.jpg`) or a full URL.
    ///   - size: desired TMDB rendition size (default `.w500`).
    /// - Returns: URL or `nil` if `path` is empty or `"null"`.
    @inlinable
    static func imageURL(path: String?, size: ImageSize = .posterDefault) -> URL? {
        guard var raw = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.lowercased() != "null" else { return nil }

        // Absolute URL passthrough (preserve existing query/fragment)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }

        // Remove leading slash to avoid double separators
        if raw.hasPrefix("/") { raw.removeFirst() }

        // Percent-encode each path segment only (not the whole string)
        let encoded = raw
            .split(separator: "/")
            .map { seg in seg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(seg) }
            .joined(separator: "/")

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
        Dictionary(uniqueKeysWithValues: genreMap.map { ($0.value.lowercased(), $0.key) })
    }()

    /// Convenience helpers
    @inlinable static func genreName(for id: Int) -> String? { genreMap[id] }
    @inlinable static func genreID(for name: String) -> Int? { reverseGenreMap[name.lowercased()] }
}

// MARK: - Private helpers

/// Reads a string from ENV or Info.plist (ENV wins), trims it, and enforces presence in Debug.
/// In Release, returns empty string on failure so callers can fail gracefully.
@inline(__always)
private func requiredPlistString(key: String, debugLabel: String) -> String {
    let env = ProcessInfo.processInfo.environment[key]
    let plist = Bundle.main.object(forInfoDictionaryKey: key) as? String
    let raw = (env?.isEmpty == false ? env : plist)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !raw.isEmpty else {
        #if DEBUG
        fatalError("❌ Missing \(debugLabel) in Info.plist or ENV. Configure per scheme.")
        #else
        Log.warn("Missing \(debugLabel); returning empty string for graceful failure in Release.")
        return ""
        #endif
    }
    return raw
}

// MARK: - BCP-47 canonicalization

/// Canonicalizes odd forms like "en_US" → "en-US", fixes casing, and falls back to "en-US".
@inline(__always)
private func canonicalBCP47(_ tag: String) -> String {
    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return fallbackBCP47() }

    // Normalize separators and split
    let parts = trimmed
        .replacingOccurrences(of: "_", with: "-")
        .split(separator: "-")
        .map(String.init)

    guard !parts.isEmpty else { return fallbackBCP47() }

    var language = parts[safe: 0]?.lowercased() ?? "en"
    if language.count < 2 || language.count > 8 { language = "en" }

    var region = parts.count >= 2 ? parts[1] : (Locale.current.regionCode ?? Locale.current.region?.identifier ?? "US")
    if region.count == 2 { region = region.uppercased() } // "us" -> "US"

    return "\(language)-\(region)"
}

@inline(__always)
private func fallbackBCP47() -> String {
    let lang = (Locale.preferredLanguages.first ?? "en").split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
    let region = (Locale.current.regionCode ?? Locale.current.region?.identifier ?? "US").uppercased()
    return "\(lang)-\(region)"
}

// MARK: - Small conveniences

private extension Array {
    subscript (safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
