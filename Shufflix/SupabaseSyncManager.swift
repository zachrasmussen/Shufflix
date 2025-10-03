//
//  SupabaseSyncManager.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/1/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import os

// MARK: - SupabaseSyncManager

final class SupabaseSyncManager {
  // MARK: Dependencies
  private let sdb: SupabaseService
  private let isoFmtFrac: ISO8601DateFormatter
  private let isoFmtNoFrac: ISO8601DateFormatter
  private let lastKey: String
  private let pushLimiter = AsyncLimiter(limit: 6)  // cap concurrent upserts
  private let gate = Gate()                         // prevents overlapping syncs
  private let log: Logger? = {
    #if DEBUG
    if #available(iOS 14.0, *) {
      return Logger(subsystem: Bundle.main.bundleIdentifier ?? "Shufflix", category: "Sync")
    }
    #endif
    return nil
  }()

  // MARK: Config
  private let defaultCursor = "1970-01-01T00:00:00Z"

  init(service: SupabaseService = SupabaseService(), pushConcurrency: Int = 6) {
    self.sdb = service
    self.lastKey = "com.shufflix.sync.lastServerISO.\(Constants.App.env)"
    self.pushLimiter.setLimit(max(1, pushConcurrency))

    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.isoFmtFrac = f1

    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    self.isoFmtNoFrac = f2

    // Initialize cursor if missing
    if UserDefaults.standard.string(forKey: lastKey) == nil {
      UserDefaults.standard.set(defaultCursor, forKey: lastKey)
    }
  }

  // MARK: - Cursor

  private var lastISO: String {
    get { UserDefaults.standard.string(forKey: lastKey) ?? defaultCursor }
    set { UserDefaults.standard.set(newValue, forKey: lastKey) }
  }

  /// Manually reset the cursor (useful for troubleshooting).
  func resetCursor() { lastISO = defaultCursor }

  /// Force the cursor to a specific ISO8601 string.
  func setCursor(_ iso: String) { lastISO = iso }

  // MARK: - Public Orchestrators

  /// Fire-and-forget “do both” helper you can call at app foreground / good network.
  func syncNow(pending: [UserTitle], mergeInto deck: DeckViewModel) {
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
        try? await self.gate.enter()
        defer { Task { await self.gate.leave() } }

      try Task.checkCancellation()
      await self.pushLocalActionsIfAny(pending)

      try Task.checkCancellation()
      await self.pullServerDeltas(mergeInto: deck)
    }
  }

  // MARK: - Push (local → server)

  /// Push a batch of local actions to Supabase.
  /// - Runs off-main, with capped concurrency.
  /// - Failures are logged and do not abort the batch.
  func pushLocalActionsIfAny(_ pending: [UserTitle]) async {
    guard !pending.isEmpty else { return }

    await withTaskGroup(of: Void.self) { group in
      for ut in pending {
        group.addTask { [weak self] in
          guard let self else { return }
          await self.pushLimiter.acquire()
          defer { Task { await self.pushLimiter.release() } }

          do {
            _ = try await self.sdb.upsertUserTitle(
              tmdbID: ut.tmdb_id,
              media: ut.media,
              liked: ut.liked,
              skipped: ut.skipped,
              seen: ut.seen,
              rating: ut.rating
            )
          } catch {
            #if DEBUG
            self.log?.fault("Push failed for \(ut.tmdb_id) \(ut.media): \(error.localizedDescription, privacy: .public)")
            #endif
          }
        }
      }
      // group waits for all
    }
  }

  // MARK: - Pull (server → local)

  /// Pull deltas newer than the last cursor and merge into the DeckViewModel.
  /// - Sorted & applied on the main actor.
  /// - Advances cursor monotonically.
  func pullServerDeltas(mergeInto deck: DeckViewModel) async {
    // Gentle retry once for transient issues
    let since = lastISO
    do {
      let deltas = try await withRetry(times: 2) { [self] in
        try await self.sdb.fetchDeltas(since: since)
      }
      guard !deltas.isEmpty else { return }

      // Sort defensively (server sends ascending but don’t assume)
      let sorted = deltas.sorted { (a, b) in
        (a.updated_at ?? "") < (b.updated_at ?? "")
      }

      // Apply to deck on main actor
      await MainActor.run {
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
      }

      // Advance cursor to max(updated_at) if newer
      if let newestISO = newestISOString(from: sorted) {
        let advanced = maxISO(a: newestISO, b: since)
        if advanced != since { lastISO = advanced }
      }
    } catch {
      #if DEBUG
      log?.fault("Delta pull failed: \(error.localizedDescription, privacy: .public)")
      #endif
    }
  }

  // MARK: - ISO helpers

  private func parseISO(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    if let d = isoFmtFrac.date(from: s) { return d }
    return isoFmtNoFrac.date(from: s)
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

  /// Returns the strictly newer of two ISO8601 strings, falling back to string compare.
  private func maxISO(a: String, b: String) -> String {
    guard let da = parseISO(a), let db = parseISO(b) else { return max(a, b) }
    return da > db ? a : b
  }

  // MARK: - Small retry helper

  private func withRetry<T>(times: Int = 2, _ op: @escaping () async throws -> T) async throws -> T {
    var lastErr: Error?
    for i in 0..<max(1, times) {
      do { return try await op() }
      catch {
        lastErr = error
        if i < times - 1 {
          // backoff 180–360ms
          try? await Task.sleep(nanoseconds: UInt64(180_000_000 + Int.random(in: 0...180) * 1_000_000))
          continue
        }
        throw error
      }
    }
    throw lastErr ?? NSError(domain: "SupabaseSyncManager", code: -1)
  }
}

// MARK: - Gate (prevents overlapping syncs)

private actor Gate {
  private var locked = false
  func enter() throws {
    if locked { throw CancellationError() } // treat overlap as cancel; caller can re-schedule
    locked = true
  }
  func leave() { locked = false }
}

// MARK: - AsyncLimiter (simple concurrency throttle)

private actor AsyncLimiter {
  private var limit: Int
  private var running = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) { self.limit = max(1, limit) }

  func setLimit(_ new: Int) { self.limit = max(1, new) }

  func acquire() async {
    if running < limit {
      running += 1
      return
    }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      waiters.append(cont)
    }
    running += 1
  }

  func release() {
    running = max(0, running - 1)
    if !waiters.isEmpty {
      waiters.removeFirst().resume()
    }
  }
}
