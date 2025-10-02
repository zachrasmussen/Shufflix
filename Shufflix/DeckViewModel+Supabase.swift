//
//  DeckViewModel+Supabase.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/01/25.
//  Updated 10/02/25 — Supabase helpers + safe writes
//

import Foundation
import Supabase

@MainActor
extension DeckViewModel {
  // MARK: - Convenience
  private var sdb: SupabaseService { SupabaseService() }

  // MARK: - Remote reads (Liked)
 
  /// Hydrates `likedCache` (names/posters) for the liked rows using the Titles cache table.
    @MainActor
    func hydrateLikedCacheFromSupabase() async {
        // Deduplicate (tmdb_id, media) pairs using a string key
        var seen = Set<String>()
        var pairs: [(Int64, String)] = []

        for row in likedFromRemote {
            let key = "\(row.tmdb_id)-\(row.media)"
            if !seen.contains(key) {
                seen.insert(key)
                pairs.append((Int64(row.tmdb_id), row.media))
            }
        }

        guard !pairs.isEmpty else {
            self.likedCache = []
            print("likedCache hydrated: 0")
            return
        }

        do {
            let cache = try await SupabaseService().fetchTitleCache(ids: pairs)
            self.likedCache = cache
            print("likedCache hydrated:", cache.count)
        } catch {
            print("hydrateLikedCacheFromSupabase error:", error)
        }
    }


  // MARK: - Remote writes (Upserts)
  /// Like a title (and optionally upsert minimal cache so lists render offline quickly).
  func like(tmdbID: Int64, media: String, cache: TitleCache? = nil) {
    // ---- Optimistic local update (optional)
    // TODO: Update your local store/UI immediately so the card disappears and list updates.
    // e.g., self.store.like(item: someTitleItem)

    Task {
      do {
        if let c = cache {
          _ = try await sdb.upsertTitleCache(c)
        }
        _ = try await sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          liked: true
        )
        // Success: fire haptics, enqueue refresh if needed
      } catch {
        // ---- Optional revert of optimistic change
        // e.g., self.store.unlike(item.id)
        print("Supabase like failed:", error)
      }
    }
  }

  /// Rate a title (1–5). `SupabaseService` clamps to 1–5 before sending.
  func rate(tmdbID: Int64, media: String, stars: Int) {
    // ---- Optimistic local update (optional)
    // e.g., self.store.rate(item.id, stars: stars)

    Task {
      do {
        _ = try await sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          rating: stars
        )
      } catch {
        // ---- Optional revert
        print("Supabase rate failed:", error)
      }
    }
  }

  /// Skip (don’t resurface)
  func skip(tmdbID: Int64, media: String) {
    // ---- Optimistic local update (optional)
    // e.g., self.store.markSkipped(item.id)

    Task {
      do {
        _ = try await sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          skipped: true
        )
      } catch {
        // ---- Optional revert
        print("Supabase skip failed:", error)
      }
    }
  }

  /// Mark as seen (watched)
  func markSeen(tmdbID: Int64, media: String) {
    // ---- Optimistic local update (optional)
    // e.g., self.store.markSeen(item.id)

    Task {
      do {
        _ = try await sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          seen: true
        )
      } catch {
        // ---- Optional revert
        print("Supabase seen failed:", error)
      }
    }
  }

  // MARK: - Server → Local merge hook (for future sync)
  /// Merge a server row into local state (called by your sync manager).
  func applyServerRow(tmdbID: Int64,
                      media: String,
                      liked: Bool,
                      skipped: Bool,
                      seen: Bool,
                      rating: Int?) {
    // TODO: Write the server truth into your JSONLibraryStore so local/UI matches server.
    // e.g.:
    // self.store.applyServer(
    //   id: Int(tmdbID), media: media,
    //   liked: liked, skipped: skipped, seen: seen, rating: rating
    // )
  }
}
