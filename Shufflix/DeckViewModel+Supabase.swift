//
//  DeckViewModel+Supabase.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/01/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import Supabase

@MainActor
extension DeckViewModel {
  // MARK: - Convenience
  private var sdb: SupabaseService { SupabaseService() }

  // MARK: - Remote reads (Liked)

  /// Hydrates `likedCache` (names/posters) for the liked rows using the Titles cache table.
  func hydrateLikedCacheFromSupabase() async {
    var seen = Set<String>()
    let pairs = likedFromRemote.compactMap { row -> (Int64, String)? in
      let key = "\(row.tmdb_id)-\(row.media)"
      guard seen.insert(key).inserted else { return nil }
      return (row.tmdb_id, row.media)
    }

    guard !pairs.isEmpty else {
      likedCache = []
      #if DEBUG
      print("[Supabase] likedCache hydrated: 0")
      #endif
      return
    }

    do {
      let cache = try await sdb.fetchTitleCache(ids: pairs)
      likedCache = cache
      #if DEBUG
      print("[Supabase] likedCache hydrated:", cache.count)
      #endif
    } catch {
      logSupabaseError("hydrateLikedCacheFromSupabase", error: error)
    }
  }

  // MARK: - Remote writes (Upserts)

  func like(tmdbID: Int64, media: String, cache: TitleCache? = nil) {
    Task(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        if let c = cache {
          _ = try await self.sdb.upsertTitleCache(c)
        }
        _ = try await self.sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          liked: true
        )
      } catch {
        self.logSupabaseError("like", error: error)
      }
    }
  }

  func rate(tmdbID: Int64, media: String, stars: Int) {
    Task(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          rating: stars
        )
      } catch {
        self.logSupabaseError("rate", error: error)
      }
    }
  }

  func skip(tmdbID: Int64, media: String) {
    Task(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          skipped: true
        )
      } catch {
        self.logSupabaseError("skip", error: error)
      }
    }
  }

  func markSeen(tmdbID: Int64, media: String) {
    Task(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          seen: true
        )
      } catch {
        self.logSupabaseError("markSeen", error: error)
      }
    }
  }

  // MARK: - Server → Local merge hook

  func applyServerRow(
    tmdbID: Int64,
    media: String,
    liked: Bool,
    skipped: Bool,
    seen: Bool,
    rating: Int?
  ) {
    store.applyServer(
      id: Int(tmdbID),
      media: media,
      liked: liked,
      skipped: skipped,
      seen: seen,
      rating: rating
    )
  }

  // MARK: - Error logging

  nonisolated private func logSupabaseError(_ context: String, error: Error) {
    #if DEBUG
    print("[Supabase] \(context) failed:", error.localizedDescription)
    #endif
    Task { @MainActor in
      self.errorMessage = error.localizedDescription
    }
  }
}
