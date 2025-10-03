//
//  SupabaseService.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/01/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import Supabase
import PostgREST   // PostgrestClient

// MARK: - Errors

enum SupabaseServiceError: Error, LocalizedError {
  case notAuthenticated
  case emptyResponse
  case decoding(String)
  case rateLimited
  case unauthorized
  case forbidden
  case conflict
  case server(String)
  case transport(Error)
  case unknown(Error)

  var errorDescription: String? {
    switch self {
    case .notAuthenticated: return "Not signed in."
    case .emptyResponse:    return "No data returned."
    case .decoding(let m):  return "Decoding failed: \(m)"
    case .rateLimited:      return "Too many requests. Please try again."
    case .unauthorized:     return "Unauthorized."
    case .forbidden:        return "Forbidden."
    case .conflict:         return "Write conflict."
    case .server(let m):    return "Server error: \(m)"
    case .transport(let e): return e.localizedDescription
    case .unknown(let e):   return e.localizedDescription
    }
  }
}

// MARK: - Write models

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
  private let decoder: JSONDecoder

  init(client: SupabaseClient = Supa.client) {
    self.client = client
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    self.decoder = d
  }

  // MARK: - Helpers

  /// Returns the current authenticated user's UUID or throws if not signed in.
  private func currentUserID() async throws -> UUID {
    if let user = client.auth.currentUser { return user.id }
    if let session = try? await client.auth.session {
      return session.user.id   // session.user is non-optional in newer SDKs
    }
    throw SupabaseServiceError.notAuthenticated
  }

  /// Small retry helper for transient errors (idempotent ops only).
  private func withRetry<T>(
    attempts: Int = 2,
    _ op: @escaping () async throws -> T
  ) async throws -> T {
    var lastError: Error?
    for i in 0..<max(1, attempts) {
      do { return try await op() }
      catch {
        lastError = error
        if case SupabaseServiceError.rateLimited = error {
          try? await Task.sleep(nanoseconds: UInt64(200_000_000 + Int.random(in: 0...200) * 1_000_000))
          continue
        }
        if case SupabaseServiceError.server = error, i == 0 {
          try? await Task.sleep(nanoseconds: UInt64(150_000_000 + Int.random(in: 0...150) * 1_000_000))
          continue
        }
        if let urlErr = error as? URLError {
          switch urlErr.code {
          case .timedOut, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
            if i == 0 {
              try? await Task.sleep(nanoseconds: UInt64(150_000_000 + Int.random(in: 0...150) * 1_000_000))
              continue
            }
          default: break
          }
        }
        throw error
      }
    }
    throw SupabaseServiceError.unknown(lastError ?? NSError(domain: "SupabaseService", code: -1))
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try decoder.decode(T.self, from: data) }
    catch {
      let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
      throw SupabaseServiceError.decoding("\(error.localizedDescription) — body: \(snippet)")
    }
  }

  private func mapPostgrestError(_ error: Error) -> SupabaseServiceError {
    if let uerr = error as? URLError { return .transport(uerr) }
    let msg = String(describing: error)
    if msg.contains("429") { return .rateLimited }
    if msg.contains("401") { return .unauthorized }
    if msg.contains("403") { return .forbidden }
    if msg.contains("409") { return .conflict }
    if msg.contains("HTTP"), msg.contains("5") { return .server(msg) }
    return .unknown(error)
  }

  // MARK: - Public convenience

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
    let uid = try await currentUserID()

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

    do {
      let res = try await withRetry { [self] in
        try await self.db
          .from("user_titles")
          .upsert(write, onConflict: "user_id,tmdb_id,media,app_env")
          .select()
          .execute()
      }
      let rows = try decode([UserTitle].self, from: res.data)
      guard let first = rows.first else { throw SupabaseServiceError.emptyResponse }
      return first
    } catch {
      throw mapPostgrestError(error)
    }
  }

  // MARK: - Titles cache (best effort)

  @discardableResult
  func upsertTitleCache(_ t: TitleCache) async throws -> TitleCache {
    struct TitleCacheWrite: Encodable {
      let tmdb_id: Int64
      let media: String
      let name: String?
      let poster_path: String?
      let release_date: String?
    }

    let write = TitleCacheWrite(
      tmdb_id: t.tmdb_id,
      media: t.media ?? "movie",
      name: t.name,
      poster_path: t.poster_path,
      release_date: t.release_date
    )

    do {
      _ = try await withRetry { [self] in
        try await self.db
          .from("titles")
          .upsert(write, onConflict: "tmdb_id,media")
          .execute()
      }
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
    do {
      let res = try await db
        .from("user_titles")
        .select()
        .eq("liked", value: true)
        .eq("app_env", value: Constants.App.env)
        .order("updated_at", ascending: false)
        .execute()

      return try decode([UserTitle].self, from: res.data)
    } catch {
      throw mapPostgrestError(error)
    }
  }

  func fetchDeltas(since isoTimestamp: String, limit: Int = 1000) async throws -> [UserTitle] {
    do {
      let res = try await db
        .from("user_titles")
        .select()
        .gt("updated_at", value: isoTimestamp)
        .eq("app_env", value: Constants.App.env)
        .order("updated_at", ascending: true)
        .limit(limit)
        .execute()

      return try decode([UserTitle].self, from: res.data)
    } catch {
      throw mapPostgrestError(error)
    }
  }

  /// Fetch cached titles by (id, media) pairs. Batches large queries to avoid URL/SQL limits.
  func fetchTitleCache(ids: [(Int64, String)]) async throws -> [TitleCache] {
    guard !ids.isEmpty else { return [] }

    let uniqueIDs: [Int] = Array(Set(ids.map { Int($0.0) }))

    let chunkSize = 900
    var all: [TitleCache] = []
    all.reserveCapacity(uniqueIDs.count)

    do {
      try await withThrowingTaskGroup(of: [TitleCache].self) { group in
        for chunk in uniqueIDs.chunked(into: chunkSize) {
          group.addTask { [self] in
            let res = try await self.db
              .from("titles")
              .select()
              .in("tmdb_id", values: chunk)
              .execute()
            return try self.decode([TitleCache].self, from: res.data)
          }
        }
        for try await part in group { all += part }
      }
    } catch {
      throw mapPostgrestError(error)
    }

    let wanted = Set(ids.map { "\($0.0)-\($0.1)" })
    var seen = Set<String>()
    var out: [TitleCache] = []
    out.reserveCapacity(all.count)

    for t in all {
      let key = "\(t.tmdb_id)-\(t.media)"
      if wanted.contains(key), seen.insert(key).inserted {
        out.append(t)
      }
    }

    return out
  }
}

// MARK: - Small utilities

private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    var result: [[Element]] = []
    result.reserveCapacity((count / size) + 1)
    var i = 0
    while i < count {
      let j = Swift.min(i + size, count)
      result.append(Array(self[i..<j]))
      i = j
    }
    return result
  }
}
