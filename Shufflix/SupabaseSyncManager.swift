//
//  SupabaseSyncManager.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/1/25.
//  Refactored: 2025-10-02
//

import Foundation

@MainActor
final class SupabaseSyncManager {
  private let sdb: SupabaseService
  private let isoFmt: ISO8601DateFormatter
  private let lastKey: String

  /// Limit for concurrent push upserts.
  private let pushConcurrency: Int

  init(
    service: SupabaseService = SupabaseService(),
    pushConcurrency: Int = 6
  ) {
    self.sdb = service
    self.pushConcurrency = max(1, pushConcurrency)

    // Env-scoped key so staging/prod maintain independent cursors.
    self.lastKey = "com.shufflix.sync.lastServerISO.\(Constants.App.env)"

    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.isoFmt = f

    // Initialize cursor if missing
    if UserDefaults.standard.string(forKey: lastKey) == nil {
      UserDefaults.standard.set("1970-01-01T00:00:00Z", forKey: lastKey)
    }
  }

  // MARK: - Cursor

  private var lastISO: String {
    get { UserDefaults.standard.string(forKey: lastKey) ?? "1970-01-01T00:00:00Z" }
    set { UserDefaults.standard.set(newValue, forKey: lastKey) }
  }

  /// Manually reset the cursor (useful for troubleshooting).
  func resetCursor() { lastISO = "1970-01-01T00:00:00Z" }

  /// Force the cursor to a specific ISO8601 string.
  func setCursor(_ iso: String) { lastISO = iso }

  // MARK: - Push (local → server)

  /// Push a batch of local actions to Supabase.
  /// - Note: Runs with capped concurrency; failures are logged and do not abort the batch.
  func pushLocalActionsIfAny(_ pending: [UserTitle]) async {
    guard !pending.isEmpty else { return }

    // Concurrency throttle
    await withTaskGroup(of: Void.self) { group in
      var idx = 0
      var inFlight = 0

      func addTask(_ ut: UserTitle) {
        group.addTask { [sdb] in
          do {
            _ = try await sdb.upsertUserTitle(
              tmdbID: ut.tmdb_id,
              media: ut.media,
              liked: ut.liked,
              skipped: ut.skipped,
              seen: ut.seen,
              rating: ut.rating
            )
          } catch {
            #if DEBUG
            print("[Sync] Push failed for \(ut.key): \(error)")
            #endif
          }
        }
      }

      while idx < pending.count {
        if inFlight < pushConcurrency {
          addTask(pending[idx]); idx += 1; inFlight += 1
        } else {
          // Wait for one to complete before adding the next
          await group.next()
          inFlight -= 1
        }
      }

      // Drain remaining
      while inFlight > 0 {
        await group.next()
        inFlight -= 1
      }
    }
  }

  // MARK: - Pull (server → local)

  /// Pull deltas newer than the last cursor and merge into the DeckViewModel.
  func pullServerDeltas(mergeInto deck: DeckViewModel) async {
    do {
      let sinceISO = lastISO
      let deltas = try await sdb.fetchDeltas(since: sinceISO)
      guard !deltas.isEmpty else { return }

      // Apply in order (server already sorts ascending, but we’ll be defensive)
      let sorted = deltas.sorted { (a, b) in
        (a.updated_at ?? "") < (b.updated_at ?? "")
      }

      for ut in sorted {
        deck.applyServerRow(
          tmdbID: ut.tmdb_id,
          media: ut.media,
          liked: ut.liked,
          skipped: ut.skipped,
          seen: ut.seen,
          rating: ut.rating
        )
      }

      // Advance cursor to max(updated_at)
      if let newestISO = newestISOString(from: sorted) {
        // Only move forward
        if isNewer(newestISO, than: sinceISO) {
          lastISO = newestISO
        }
      }
    } catch {
      #if DEBUG
      print("[Sync] Delta pull failed: \(error)")
      #endif
    }
  }

  // MARK: - ISO helpers

  private func parseISO(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    // Try with fractional seconds first, then without
    if let d = isoFmt.date(from: s) { return d }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
  }

  private func newestISOString(from rows: [UserTitle]) -> String? {
    var newestDate: Date?
    var newestStr: String?

    for r in rows {
      guard let iso = r.updated_at, let d = parseISO(iso) else { continue }
      if newestDate == nil || d > newestDate! {
        newestDate = d
        newestStr = iso
      }
    }
    return newestStr
  }

  private func isNewer(_ a: String, than b: String) -> Bool {
    guard let da = parseISO(a), let db = parseISO(b) else { return a > b }
    return da > db
  }
}
