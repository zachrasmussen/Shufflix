//
//  SupabaseSyncManager.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/1/25.
//

import Foundation

@MainActor
final class SupabaseSyncManager {
  private let sdb = SupabaseService()
  private let lastKey = "com.quickflix.sync.lastServerISO"

  private var lastISO: String {
    get { UserDefaults.standard.string(forKey: lastKey) ?? "1970-01-01T00:00:00Z" }
    set { UserDefaults.standard.set(newValue, forKey: lastKey) }
  }

  func pushLocalActionsIfAny(_ pending: [UserTitle]) async {
    for ut in pending {
      do {
        _ = try await sdb.upsertUserTitle(
          tmdbID: ut.tmdb_id, media: ut.media,
          liked: ut.liked, skipped: ut.skipped, seen: ut.seen, rating: ut.rating
        )
      } catch {
        print("Push failed for \(ut.key):", error)
      }
    }
  }

  func pullServerDeltas(mergeInto deck: DeckViewModel) async {
    do {
      let deltas = try await sdb.fetchDeltas(since: lastISO)
      guard !deltas.isEmpty else { return }

      // Merge into your local store
      for ut in deltas {
        deck.applyServerRow(tmdbID: ut.tmdb_id, media: ut.media,
                            liked: ut.liked, skipped: ut.skipped, seen: ut.seen, rating: ut.rating)
      }

      // Update last sync to newest row
      if let newest = deltas.last?.updated_at { lastISO = newest }
    } catch {
      print("Delta pull failed:", error)
    }
  }
}
