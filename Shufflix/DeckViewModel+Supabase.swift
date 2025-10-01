//
//  DeckViewModel+Supabase.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/01/25.
//

import Foundation

@MainActor
extension DeckViewModel {
  /// Convenience accessor
  private var sdb: SupabaseService { SupabaseService() }

  /// Like a title (and optionally upsert minimal cache so lists render offline quickly).
  func like(tmdbID: Int64, media: String, cache: TitleCache? = nil) {
    // ---- Optimistic local update (optional)
    // TODO: Update your local store/UI immediately so the card disappears and list updates.
    // e.g., self.store.markLiked(id: Int(tmdbID), media: media)

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
        // Success: you can fire haptics, etc.
      } catch {
        // ---- Optional revert of optimistic change
        // TODO: Revert local change if you did an optimistic update.
        // e.g., self.store.unlike(id: Int(tmdbID), media: media)
        print("Supabase like failed:", error)
      }
    }
  }

  /// Rate a title (1–5 stars)
  func rate(tmdbID: Int64, media: String, stars: Int) {
    // ---- Optimistic local update (optional)
    // TODO: Apply rating locally so UI reflects new stars immediately.
    // e.g., self.store.setRating(id: Int(tmdbID), media: media, stars: stars)

    Task {
      do {
        _ = try await sdb.upsertUserTitle(
          tmdbID: tmdbID,
          media: media,
          rating: stars
        )
      } catch {
        // ---- Optional revert
        // TODO: Revert local rating if needed.
        print("Supabase rate failed:", error)
      }
    }
  }

  /// Skip (don’t resurface)
  func skip(tmdbID: Int64, media: String) {
    // ---- Optimistic local update (optional)
    // TODO: Remove from deck locally so it doesn’t resurface.
    // e.g., self.store.markSkipped(id: Int(tmdbID), media: media)

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
    // TODO: Update local state (and lists) for “seen”.
    // e.g., self.store.markSeen(id: Int(tmdbID), media: media)

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
