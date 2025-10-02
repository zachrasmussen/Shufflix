//
//  SupabaseService.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/01/25.
//  Refactored: 2025-10-02
//

import Foundation
import Supabase
import PostgREST   // PostgrestClient

// MARK: - Errors

enum SupabaseServiceError: Error {
  case notAuthenticated
  case emptyResponse
}

// MARK: - Write models

/// Minimal write payload for `public.user_titles`.
/// Explicit booleans so behavior is deterministic on upsert.
private struct UserTitleWrite: Encodable {
  let user_id: UUID
  let tmdb_id: Int64
  let media: String            // "movie" | "tv"
  let liked: Bool
  let skipped: Bool
  let seen: Bool
  let rating: Int?
  let app_env: String          // "prod" | "staging"
}

// MARK: - Service

final class SupabaseService {
  private let client: SupabaseClient
  private var db: PostgrestClient { client.database }
  private let decoder = JSONDecoder()

  init(client: SupabaseClient = Supa.client) {
    self.client = client
  }

  // MARK: - Helpers

  /// Returns the current authenticated user's UUID or throws if not signed in.
  private func currentUserID() throws -> UUID {
    if let user = client.auth.currentUser { return user.id }
    throw SupabaseServiceError.notAuthenticated
  }

  // MARK: - Public convenience (used by DeckViewModel+Supabase)

  @discardableResult
  func setLiked(tmdbID: Int64, media: MediaType, liked: Bool) async throws -> UserTitle {
    try await upsertUserTitle(
      tmdbID: tmdbID,
      media: media.rawValue,
      liked: liked,
      skipped: nil,
      seen: nil,
      rating: nil
    )
  }

  @discardableResult
  func setSkipped(tmdbID: Int64, media: MediaType, skipped: Bool) async throws -> UserTitle {
    try await upsertUserTitle(
      tmdbID: tmdbID,
      media: media.rawValue,
      liked: nil,
      skipped: skipped,
      seen: nil,
      rating: nil
    )
  }

  @discardableResult
  func setSeen(tmdbID: Int64, media: MediaType, seen: Bool) async throws -> UserTitle {
    try await upsertUserTitle(
      tmdbID: tmdbID,
      media: media.rawValue,
      liked: nil,
      skipped: nil,
      seen: seen,
      rating: nil
    )
  }

  @discardableResult
  func setRating(tmdbID: Int64, media: MediaType, rating: Int?) async throws -> UserTitle {
    try await upsertUserTitle(
      tmdbID: tmdbID,
      media: media.rawValue,
      liked: nil,
      skipped: nil,
      seen: nil,
      rating: rating
    )
  }

  // MARK: - Core write (env-aware upsert)

  @discardableResult
  func upsertUserTitle(
    tmdbID: Int64,
    media: String,
    liked: Bool? = nil,
    skipped: Bool? = nil,
    seen: Bool? = nil,
    rating: Int? = nil
  ) async throws -> UserTitle {
    let uid = try currentUserID()

    let clampedRating: Int? = rating.map { max(1, min(5, $0)) }

    let write = UserTitleWrite(
      user_id: uid,
      tmdb_id: tmdbID,
      media: media,
      liked: liked ?? false,
      skipped: skipped ?? false,
      seen: seen ?? false,
      rating: clampedRating,
      app_env: Constants.App.env
    )

    let response = try await db
      .from("user_titles")
      .upsert(write, onConflict: "user_id,tmdb_id,media,app_env")
      .execute()

    let rows = try decoder.decode([UserTitle].self, from: response.data)
    guard let first = rows.first else { throw SupabaseServiceError.emptyResponse }
    return first
  }

  // MARK: - Titles cache (best effort)
  //
  // If RLS restricts writes to service_role, we try and then gracefully no-op on failure.

  @discardableResult
  func upsertTitleCache(_ t: TitleCache) async throws -> TitleCache {
    // Make `name` optional (DB column allows NULL), and coalesce `media` if your model has it optional.
    struct TitleCacheWrite: Encodable {
      let tmdb_id: Int64
      let media: String
      let name: String?
      let poster_path: String?
      let release_date: String?
    }

    let write = TitleCacheWrite(
      tmdb_id: t.tmdb_id,
      media: t.media ?? "movie",     // 👈 coalesce if your model uses String?
      name: t.name,                  // 👈 optional ok
      poster_path: t.poster_path,    // optional
      release_date: t.release_date   // optional
    )

    do {
      _ = try await db
        .from("titles")
        .upsert(write, onConflict: "tmdb_id,media")
        .execute()
      return t
    } catch {
      #if DEBUG
      print("[Supabase] upsertTitleCache best-effort failed:", error)
      #endif
      return t
    }
  }

  // MARK: - Reads (env-aware)

  func fetchLiked() async throws -> [UserTitle] {
    let res = try await db
      .from("user_titles")
      .select()
      .eq("liked", value: true)
      .eq("app_env", value: Constants.App.env)
      .order("updated_at", ascending: false)
      .execute()

    return try decoder.decode([UserTitle].self, from: res.data)
  }

  func fetchDeltas(since isoTimestamp: String) async throws -> [UserTitle] {
    let res = try await db
      .from("user_titles")
      .select()
      .gt("updated_at", value: isoTimestamp)
      .eq("app_env", value: Constants.App.env)
      .order("updated_at", ascending: true)
      .execute()

    return try decoder.decode([UserTitle].self, from: res.data)
  }

  func fetchTitleCache(ids: [(Int64, String)]) async throws -> [TitleCache] {
    guard !ids.isEmpty else { return [] }

    let uniqueIDs: [Int] = Array(Set(ids.map { Int($0.0) }))

    let res = try await db
      .from("titles")
      .select()
      .in("tmdb_id", values: uniqueIDs)
      .execute()

    var titles = try decoder.decode([TitleCache].self, from: res.data)

    // Filter to only requested (id, media) pairs
    let wanted = Set(ids.map { "\($0.0)-\($0.1)" })
    titles.removeAll { !wanted.contains("\($0.tmdb_id)-\($0.media)") }

    return titles
  }
}
