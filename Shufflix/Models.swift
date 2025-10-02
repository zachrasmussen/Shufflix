//
//  Models.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Refactored: 2025-10-02
//

import Foundation
import PostgREST   // for AnyJSON (jsonb)

// MARK: - Media

@frozen
enum MediaType: String, Codable {
    case movie
    case tv
    case unknown

    var isMovie: Bool { self == .movie }
    var isTV:    Bool { self == .tv }

    // Graceful decode: unrecognized → .unknown (never throws)
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.lowercased() ?? ""
        self = MediaType.fromLoose(raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Maps arbitrary strings to a safe MediaType
    static func fromLoose(_ raw: String) -> MediaType {
        switch raw.lowercased() {
        case "movie": return .movie
        case "tv":    return .tv
        default:      return .unknown
        }
    }
}

// =====================================================================
// MARK: - Providers
// =====================================================================

struct ProviderLink: Hashable, Codable {
    let name: String
    let url: URL
    let logoURL: URL?
}

// =====================================================================
// MARK: - Titles (UI-facing)
// =====================================================================

struct TitleItem: Identifiable, Hashable, Codable {
    let id: Int
    let mediaType: MediaType
    let name: String
    let year: String
    let overview: String
    let posterURL: URL?
    let genres: [String]
    let providers: [ProviderLink]
    let tmdbRating: Double?
    let tmdbVoteCount: Int?
}

// MARK: UI Helpers

extension TitleItem {
    var hasPoster: Bool { posterURL != nil }
    var primaryGenre: String? { genres.first }

    /// e.g., "7.9 (82k)" or "—" if no votes
    var ratingText: String {
        guard let tmdbRating, let votes = tmdbVoteCount, votes > 0 else { return "—" }

        let votesText: String
        if votes >= 1_000 {
            // 1,200 → "1.2k"   82,000 → "82k"
            let thousands = Double(votes) / 1_000.0
            votesText = thousands >= 10
                ? String(format: "%.0fk", thousands)
                : String(format: "%.1fk", thousands)
        } else {
            votesText = "\(votes)"
        }
        return String(format: "%.1f (%@)", tmdbRating, votesText)
    }
}

// =====================================================================
// MARK: - Ratings
// =====================================================================

@frozen
enum StarRating: Int, Codable, CaseIterable {
    case one = 1, two, three, four, five

    init?(clamping value: Int) {
        guard (1...5).contains(value) else { return nil }
        self.init(rawValue: value)
    }
}

// =====================================================================
// MARK: - Persistence Snapshot (local JSON)
// =====================================================================

/// Lightweight persistence form of `TitleItem` (Codable).
struct StoredTitle: Codable, Hashable {
    let id: Int
    let mediaType: String
    let name: String
    let year: String
    let posterURLString: String?
    let genres: [String]
    let overview: String?
    let tmdbRating: Double?
    let tmdbVoteCount: Int?
    /// Optional providers (newer schema); older persisted files may omit.
    let providers: [ProviderLink]?
}

// MARK: Conversions (UI <-> Persistence)

extension TitleItem {
    var stored: StoredTitle {
        StoredTitle(
            id: id,
            mediaType: mediaType.rawValue,
            name: name,
            year: year,
            posterURLString: posterURL?.absoluteString,
            genres: genres,
            overview: overview.isEmpty ? nil : overview,
            tmdbRating: tmdbRating,
            tmdbVoteCount: tmdbVoteCount,
            providers: providers.isEmpty ? nil : providers
        )
    }
}

extension StoredTitle {
    func asTitleItem() -> TitleItem {
        TitleItem(
            id: id,
            mediaType: MediaType.fromLoose(mediaType),
            name: name,
            year: year,
            overview: overview ?? "",
            posterURL: posterURLString.flatMap(URL.init(string:)),
            genres: genres,
            providers: providers ?? [],
            tmdbRating: tmdbRating,
            tmdbVoteCount: tmdbVoteCount
        )
    }
}

// =====================================================================
// MARK: - Supabase Rows (DB-facing models)
// =====================================================================

/// Mirrors `public.titles` (cache).  Snake_case fields match DB columns.
struct TitleCache: Codable, Identifiable, Hashable {
    // Convenience ID to use in SwiftUI lists
    var id: String { "\(tmdb_id)-\(media)" }

    let tmdb_id: Int64
    let media: String               // "movie" | "tv" (map to MediaType with .fromLoose)

    let name: String?
    let poster_path: String?
    let release_date: String?       // YYYY-MM-DD
    let popularity: Double?
    let certification: String?
    let runtime_min: Int?
    let seasons: Int?
    let providers: AnyJSON?         // jsonb
}

/// Mirrors `public.user_titles` for RLS-backed reads/writes.
struct UserTitle: Codable, Identifiable, Hashable {
    let id: UUID?
    let user_id: UUID?
    let tmdb_id: Int64
    let media: String               // "movie" | "tv"

    var liked: Bool
    var skipped: Bool
    var seen: Bool
    var rating: Int?
    let notes: String?

    let created_at: String?
    let updated_at: String?

    // Helpers
    var key: String { "\(tmdb_id)-\(media)" }
    var mediaType: MediaType { MediaType.fromLoose(media) }
    var hasAnyAction: Bool { liked || skipped || seen || rating != nil }
}

// =====================================================================
// MARK: - Conversions (DB -> UI/Persistence)
// =====================================================================

extension TitleCache {
    /// Build a minimal `StoredTitle` snapshot (offline-first list rendering).
    /// Note: `popularity` is not a rating; surface it only if you want *some* value.
    var asStoredTitle: StoredTitle {
        let poster = Constants.imageURL(path: poster_path, size: .posterDefault)?.absoluteString
        return StoredTitle(
            id: Int(tmdb_id),
            mediaType: MediaType.fromLoose(media).rawValue,
            name: name ?? "",
            year: TitleCache.yearString(from: release_date) ?? "",
            posterURLString: poster,
            genres: [],                 // hydrate via TMDB detail as needed
            overview: nil,
            tmdbRating: popularity,
            tmdbVoteCount: nil,
            providers: nil
        )
    }

    /// Extracts a 4-digit year from an ISO "YYYY-MM-DD" (tolerant).
    static func yearString(from isoDate: String?) -> String? {
        guard let s = isoDate?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Fast path: standard format
        if s.count >= 4 { return String(s.prefix(4)) }
        return nil
    }
}
