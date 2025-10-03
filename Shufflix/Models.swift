//
//  Models.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import PostgREST   // AnyJSON (jsonb)



@frozen
enum MediaType: String, Codable, Sendable {
  case movie
  case tv
  case unknown

  @inlinable var isMovie: Bool { self == .movie }
  @inlinable var isTV:    Bool { self == .tv }
  @inlinable var isKnown: Bool { self != .unknown }

  // Graceful decode: unrecognized → .unknown (never throws)
  init(from decoder: Decoder) throws {
    let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
    self = MediaType.fromLoose(raw)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(rawValue)
  }

  /// Maps arbitrary strings to a safe MediaType
  @inlinable
  static func fromLoose(_ raw: String) -> MediaType {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "movie": return .movie
    case "tv":    return .tv
    default:      return .unknown
    }
  }
}

// MARK: - Providers

struct ProviderLink: Hashable, Codable, Sendable {
  let name: String
  let url: URL
  let logoURL: URL?
}

// MARK: - Titles (UI-facing)

struct TitleItem: Identifiable, Hashable, Codable, Sendable {
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
  @inlinable var hasPoster: Bool { posterURL != nil }
  @inlinable var primaryGenre: String? { genres.first }

  /// e.g., "7.9 (82k)" or "—" if no votes. Fast and allocation-light.
  var ratingText: String {
    guard let tmdbRating, let votes = tmdbVoteCount, votes > 0 else { return "—" }

    let votesText: String
    if votes >= 1_000 {
      // 1,200 → "1.2k"   82,000 → "82k"
      let thousands = Double(votes) / 1_000.0
      if thousands >= 10 {
        votesText = Int(thousands).description + "k"
      } else {
        // Avoid NumberFormatter here; String(format:) is fine on this hot path.
        votesText = String(format: "%.1fk", thousands)
      }
    } else {
      votesText = votes.description
    }

    // Cached formatter for rating (one decimal).
    return TitleItemFormatters.oneDecimal.string(from: NSNumber(value: tmdbRating)).map {
      "\($0) (\(votesText))"
    } ?? String(format: "%.1f (\(votesText))", tmdbRating)
  }
}

private enum TitleItemFormatters {
  static let oneDecimal: NumberFormatter = {
    let nf = NumberFormatter()
    nf.locale = .current
    nf.maximumFractionDigits = 1
    nf.minimumFractionDigits = 1
    nf.minimumIntegerDigits = 1
    return nf
  }()
}

// ===========================================================
// MARK: - Ratings
// ===========================================================

@frozen
enum StarRating: Int, Codable, CaseIterable, Sendable {
  case one = 1, two, three, four, five

  @inlinable
  init?(clamping value: Int) {
    guard (1...5).contains(value) else { return nil }
    self.init(rawValue: value)
  }

  /// Returns a valid StarRating, clamping out-of-range values.
  @inlinable
  static func clamped(_ value: Int) -> StarRating {
    StarRating(rawValue: max(1, min(5, value)))!
  }
}

// MARK: - Persistence Snapshot (local JSON)

/// Lightweight persistence form of `TitleItem` (Codable).
struct StoredTitle: Codable, Hashable, Sendable {
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
  @inlinable
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
  @inlinable
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

// MARK: - Supabase Rows (DB-facing models)

/// Mirrors `public.titles` (cache). Snake_case fields match DB columns.
struct TitleCache: Codable, Identifiable, Hashable, Sendable {
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
struct UserTitle: Codable, Identifiable, Hashable, Sendable {
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
  @inlinable var key: String { "\(tmdb_id)-\(media)" }
  @inlinable var mediaType: MediaType { MediaType.fromLoose(media) }
  @inlinable var hasAnyAction: Bool { liked || skipped || seen || rating != nil }
}

// ===========================================================
// MARK: - Conversions (DB -> UI/Persistence)
// ===========================================================

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
  @inlinable
  static func yearString(from isoDate: String?) -> String? {
    guard let s = isoDate?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 4 else { return nil }
    return String(s.prefix(4))
  }
}
