//
//  SupabaseService.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/01/25.
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
  let media: String
  let liked: Bool
  let skipped: Bool
  let seen: Bool
  let rating: Int?
  let app_env: String          // <— env tag ("prod" | "staging")
}

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
    if let user = client.auth.currentUser {
      return user.id
    }
    throw SupabaseServiceError.notAuthenticated
  }

  // MARK: - Writes (direct table upserts)

  /// Upsert a user/title interaction (env-aware).
  @discardableResult
  func upsertUserTitle(
    tmdbID: Int64,
    media: String,              // "movie" | "tv"
    liked: Bool? = nil,
    skipped: Bool? = nil,
    seen: Bool? = nil,
    rating: Int? = nil
  ) async throws -> UserTitle {
    let uid = try currentUserID()

    let write = UserTitleWrite(
      user_id: uid,
      tmdb_id: tmdbID,
      media: media,
      liked: liked ?? false,
      skipped: skipped ?? false,
      seen: seen ?? false,
      rating: rating,
      app_env: Constants.App.env
    )

    // Conflict target: (user_id, tmdb_id, media, app_env)
    let response = try await db
      .from("user_titles")
      .upsert(write, onConflict: "user_id,tmdb_id,media,app_env")
      .execute()

    // Upsert returns an array; take the first row
    let rows = try decoder.decode([UserTitle].self, from: response.data)
    guard let first = rows.first else { throw SupabaseServiceError.emptyResponse }
    return first
  }

  /// Titles cache writes are blocked by RLS for client keys (service_role only).
  /// We return the input so call sites don't break.
  @discardableResult
  func upsertTitleCache(_ t: TitleCache) async throws -> TitleCache {
    return t
  }

  // MARK: - Reads (env-aware)

  /// Your List: liked = true, newest first
  func fetchLiked() async throws -> [UserTitle] {
    let res = try await db
      .from("user_titles")
      .select()
      .eq("liked", value: true)
      .eq("app_env", value: Constants.App.env)               // <— filter by env
      .order("updated_at", ascending: false)
      .execute()

    return try decoder.decode([UserTitle].self, from: res.data)
  }

  /// Pull deltas newer than a timestamp (ISO string, e.g. "2025-10-01T00:00:00Z")
  func fetchDeltas(since isoTimestamp: String) async throws -> [UserTitle] {
    let res = try await db
      .from("user_titles")
      .select()
      .gt("updated_at", value: isoTimestamp)
      .eq("app_env", value: Constants.App.env)               // <— filter by env
      .order("updated_at", ascending: true)
      .execute()

    return try decoder.decode([UserTitle].self, from: res.data)
  }

  /// Fetch cached titles by tmdb_id list (hydrates UI names/posters).
  /// If you later env-tag `titles`, add `.eq("app_env", value: Constants.App.env)` here too.
  func fetchTitleCache(ids: [(Int64, String)]) async throws -> [TitleCache] {
    guard !ids.isEmpty else { return [] }

    // Unique numeric IDs for the .in(...) filter (use Int for smoother bridging)
    let uniqueIDs: [Int] = Array(Set(ids.map { Int($0.0) }))

    let res = try await db
      .from("titles")
      .select()
      .in("tmdb_id", values: uniqueIDs)       // WHERE tmdb_id IN (...)
      .execute()

    var titles = try decoder.decode([TitleCache].self, from: res.data)

    // Keep only the requested (id, media) pairs
    let wanted = Set(ids.map { "\($0.0)-\($0.1)" })
    titles.removeAll { !wanted.contains("\($0.tmdb_id)-\($0.media)") }

    return titles
  }
}
