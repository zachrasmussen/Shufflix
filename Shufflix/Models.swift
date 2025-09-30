//
//  Models.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//Updated 9/27 - 7:45

import Foundation

// MARK: - Media

enum MediaType: String, Codable {
    case movie, tv, unknown

    var isMovie: Bool { self == .movie }
    var isTV:    Bool { self == .tv }

    // Graceful decode: unrecognized → .unknown
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.lowercased() ?? ""
        self = MediaType.fromLoose(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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

// MARK: - Providers

struct ProviderLink: Hashable, Codable {
    let name: String
    let url: URL
    let logoURL: URL?
}

// MARK: - Titles

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

// MARK: - UI Helpers

extension TitleItem {
    var hasPoster: Bool { posterURL != nil }
    var primaryGenre: String? { genres.first }

    /// e.g., "7.9 (82k)" or "—" if no votes
    var ratingText: String {
        guard let tmdbRating, let votes = tmdbVoteCount, votes > 0 else { return "—" }
        let k: String
        if votes >= 1_000 {
            k = String(format: "%dk", votes / 1_000)
        } else {
            k = "\(votes)"
        }
        return String(format: "%.1f (%@)", tmdbRating, k)
    }
}

// MARK: - Ratings

enum StarRating: Int, Codable, CaseIterable {
    case one = 1, two, three, four, five

    init?(clamping value: Int) {
        guard (1...5).contains(value) else { return nil }
        self.init(rawValue: value)
    }
}

// MARK: - Persistence Snapshot

/// Lightweight persistence form of TitleItem (Codable).
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

// MARK: - Conversions

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
