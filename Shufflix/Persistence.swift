//
//  Persistence.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import Foundation

// MARK: - Disk Model

struct UserLibrary: Codable, Equatable {
  var seenIDs: Set<Int>
  var skippedIDs: Set<Int>
  var likedIDs: Set<Int>

  /// Lightweight snapshots used to rebuild Liked list on launch.
  var liked: [StoredTitle]

  /// tmdbId : 1..5
  var ratings: [Int: Int]

  /// Last-known deck snapshot for instant launch.
  var deckSnapshot: [StoredTitle]

  // For future sync/conflict resolution
  var updatedAt: Date
  var version: Int

  init(
    seenIDs: Set<Int> = [],
    skippedIDs: Set<Int> = [],
    likedIDs: Set<Int> = [],
    liked: [StoredTitle] = [],
    ratings: [Int: Int] = [:],
    deckSnapshot: [StoredTitle] = [],
    updatedAt: Date = Date(),
    version: Int = 0
  ) {
    self.seenIDs = seenIDs
    self.skippedIDs = skippedIDs
    self.likedIDs = likedIDs
    self.liked = liked
    self.ratings = ratings
    self.deckSnapshot = deckSnapshot
    self.updatedAt = updatedAt
    self.version = version
  }

  // Robust decoding with defaults (future/backward compatible)
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.seenIDs      = try c.decodeIfPresent(Set<Int>.self, forKey: .seenIDs) ?? []
    self.skippedIDs   = try c.decodeIfPresent(Set<Int>.self, forKey: .skippedIDs) ?? []
    self.likedIDs     = try c.decodeIfPresent(Set<Int>.self, forKey: .likedIDs) ?? []
    self.liked        = try c.decodeIfPresent([StoredTitle].self, forKey: .liked) ?? []
    self.ratings      = try c.decodeIfPresent([Int: Int].self, forKey: .ratings) ?? [:]
    self.deckSnapshot = try c.decodeIfPresent([StoredTitle].self, forKey: .deckSnapshot) ?? []
    self.updatedAt    = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    self.version      = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0

    UserLibrary.repair(&self) // auto-fix common drift
  }

  // Auto-repairs for minor corruption/drift
  private static func repair(_ model: inout UserLibrary) {
    // Deduplicate liked snapshots by id, preserve order
    var seen = Set<Int>()
    model.liked = model.liked.filter { snap in
      seen.insert(snap.id).inserted
    }

    // Ensure likedIDs matches snapshot ids
    model.likedIDs.formUnion(model.liked.map(\.id))

    // Ensure ratings imply "seen"
    model.seenIDs.formUnion(model.ratings.keys)

    // Bump version if we touched anything
    model.version &+= 1
  }
}

// MARK: - Store API

protocol LibraryStore {
  var state: UserLibrary { get }
  func load() throws -> UserLibrary
  func overwrite(_ new: UserLibrary) throws
  func mutate(_ block: (inout UserLibrary) -> Void)
  func saveDebounced()
  func saveNow() throws
}

final class JSONLibraryStore: LibraryStore {
  let url: URL
  private let backupURL: URL
  private let queue = DispatchQueue(label: "shufflix.library.store", qos: .utility)

  private var _state: UserLibrary
  var state: UserLibrary { queue.sync { _state } }

  // Debounced writer
  private var pendingWrite: DispatchWorkItem?
  private let writeDebounce: TimeInterval

  init(filename: String = "user_library.json", debounce: TimeInterval = 0.3) {
    self.writeDebounce = debounce
    let base = JSONLibraryStore.makeFileURL(filename: filename)
    self.url = base
    self.backupURL = base.deletingLastPathComponent()
      .appendingPathComponent(base.lastPathComponent + ".bak")
    self._state = (try? JSONLibraryStore.read(from: self.url, backupURL: self.backupURL)) ?? UserLibrary()
  }

  func load() throws -> UserLibrary {
    try JSONLibraryStore.read(from: url, backupURL: backupURL)
  }

  func overwrite(_ new: UserLibrary) throws {
    queue.sync { self._state = new }
    try JSONLibraryStore.atomicWrite(new, to: url, backupURL: backupURL)
  }

  func mutate(_ block: (inout UserLibrary) -> Void) {
    queue.sync {
      block(&self._state)
      self._state.updatedAt = Date()
      self._state.version &+= 1
    }
  }

  func saveDebounced() {
    queue.sync {
      pendingWrite?.cancel()

      let snapshot = self._state
      let destination = self.url
      let backup = self.backupURL

      let work = DispatchWorkItem {
        do { try JSONLibraryStore.atomicWrite(snapshot, to: destination, backupURL: backup) }
        catch {
          #if DEBUG
          print("[LibraryStore] debounced write failed: \(error)")
          #endif
        }
      }
      pendingWrite = work
      queue.asyncAfter(deadline: .now() + writeDebounce, execute: work)
    }
  }

  func saveNow() throws {
    queue.sync {
      pendingWrite?.cancel()
      pendingWrite = nil
    }
    let snapshot = queue.sync { _state }
    try JSONLibraryStore.atomicWrite(snapshot, to: url, backupURL: backupURL)
  }
}

// MARK: - File IO

private extension JSONLibraryStore {
  static func makeFileURL(filename: String) -> URL {
    let fm = FileManager.default
    do {
      let base = try fm.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      // Use bundle identifier for namespacing
      let bundleID = Bundle.main.bundleIdentifier ?? "Shufflix"
      let dir = base.appendingPathComponent(bundleID, isDirectory: true)
      if !fm.fileExists(atPath: dir.path) {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: fileProtectionAttributes())
        // Exclude from iCloud backup
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(rv)
      }
      return dir.appendingPathComponent(filename)
    } catch {
      #if DEBUG
      print("[LibraryStore] fallback path due to error: \(error)")
      #endif
      let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
      return docs.appendingPathComponent(filename)
    }
  }

  static func fileProtectionAttributes() -> [FileAttributeKey: Any]? {
    #if os(iOS)
    return [ .protectionKey: FileProtectionType.completeUnlessOpen ]
    #else
    return nil
    #endif
  }

  static func read(from url: URL, backupURL: URL) throws -> UserLibrary {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601

    // Try primary
    if let data = try? Data(contentsOf: url), !data.isEmpty {
      do {
        var model = try dec.decode(UserLibrary.self, from: data)
        migrateIfNeeded(&model)
        return model
      } catch {
        #if DEBUG
        print("[LibraryStore] primary decode failed, trying backup: \(error)")
        #endif
      }
    }

    // Try backup
    if let data = try? Data(contentsOf: backupURL), !data.isEmpty {
      var model = try dec.decode(UserLibrary.self, from: data)
      migrateIfNeeded(&model)
      // attempt to restore primary from backup
      try? atomicWrite(model, to: url, backupURL: backupURL)
      return model
    }

    // Nothing on disk → fresh state
    return UserLibrary()
  }

  /// Crash-safe atomic write with backup.
  static func atomicWrite(_ value: UserLibrary, to url: URL, backupURL: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    let data = try enc.encode(value)

    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(UUID().uuidString + ".tmp")

    // 1) Write atomically to temp file
    try data.write(to: tmp, options: .atomic)

    // 2) Replace destination
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
      try fm.removeItem(at: url)
    }
    try fm.moveItem(at: tmp, to: url)

    // 3) Backup refresh (best-effort)
    try? data.write(to: backupURL, options: .atomic)

    // 4) Protection attributes (iOS only)
    #if os(iOS)
    try? fm.setAttributes(fileProtectionAttributes() ?? [:], ofItemAtPath: url.path)
    #endif
  }

  static func migrateIfNeeded(_ model: inout UserLibrary) {
    // Example future migrations:
    // if model.version < 1 { model.version = 1 }
    // if model.version < 2 { model.version = 2 }
  }
}

// MARK: - Convenience Mutators

extension JSONLibraryStore {
  func markSeen(_ id: Int) {
    mutate { $0.seenIDs.insert(id) }
    saveDebounced()
  }

  func markSkipped(_ id: Int) {
    mutate {
      $0.skippedIDs.insert(id)
      $0.seenIDs.insert(id)
    }
    saveDebounced()
  }

  func unskip(_ id: Int) {
    mutate { $0.skippedIDs.remove(id) }
    saveDebounced()
  }

  /// Legacy helper: updates only the ID set (no snapshot). Prefer `like(item:)`.
  func like(_ id: Int) {
    mutate {
      $0.likedIDs.insert(id)
      $0.seenIDs.insert(id)
    }
    saveDebounced()
  }

  /// Persist a full snapshot for the Liked list (recommended).
  func like(item: TitleItem) {
    mutate { state in
      state.likedIDs.insert(item.id)
      state.seenIDs.insert(item.id)

      let snap = item.stored
      if let idx = state.liked.firstIndex(where: { $0.id == item.id }) {
        state.liked[idx] = snap
      } else {
        state.liked.insert(snap, at: 0) // most recent first
      }
    }
    saveDebounced()
  }

  func unlike(_ id: Int) {
    mutate { state in
      state.likedIDs.remove(id)
      if let idx = state.liked.firstIndex(where: { $0.id == id }) {
        state.liked.remove(at: idx)
      }
    }
    saveDebounced()
  }

  func rate(_ id: Int, stars: Int?) {
    mutate {
      if let s = stars, s > 0 {
        $0.ratings[id] = s
        $0.seenIDs.insert(id)
      } else {
        $0.ratings.removeValue(forKey: id)
      }
    }
    saveDebounced()
  }

  // MARK: - Deck Snapshot

  func saveDeckSnapshot(_ items: [TitleItem], cap: Int = 20) {
    let snaps = items.prefix(cap).map { $0.stored }
    mutate { $0.deckSnapshot = Array(snaps) }
    saveDebounced()
  }

  func loadDeckSnapshot() -> [StoredTitle] {
    state.deckSnapshot
  }
}

// MARK: - Server merge helper (Supabase → local disk)

extension JSONLibraryStore {
  /// Apply “server truth” into the local JSON library.
  /// Note: This updates ID sets/ratings only. Liked snapshots are *not* created here;
  /// hydrate them separately (e.g., via Supabase titles cache → UI).
  func applyServer(
    id: Int,
    media: String,
    liked: Bool,
    skipped: Bool,
    seen: Bool,
    rating: Int?
  ) {
    mutate { lib in
      // liked
      if liked {
        lib.likedIDs.insert(id)
      } else {
        lib.likedIDs.remove(id)
        // also scrub any stale snapshot for this id
        if let idx = lib.liked.firstIndex(where: { $0.id == id }) {
          lib.liked.remove(at: idx)
        }
      }

      // skipped
      if skipped {
        lib.skippedIDs.insert(id)
      } else {
        lib.skippedIDs.remove(id)
      }

      // seen (server “seen” only adds, never removes local seen)
      if seen {
        lib.seenIDs.insert(id)
      }

      // rating (1–5 or nil to clear)
      if let r = rating, r > 0 {
        lib.ratings[id] = min(5, max(1, r))
        lib.seenIDs.insert(id) // rating implies seen
      } else {
        lib.ratings.removeValue(forKey: id)
      }
    }
    saveDebounced()
  }
}

// MARK: - Option: Bundled Seed Loader

enum SeedLoader {
  static func loadSeed() -> [StoredTitle] {
    guard let url = Bundle.main.url(forResource: "seed_titles", withExtension: "json"),
          let data = try? Data(contentsOf: url) else { return [] }

    do {
      return try JSONDecoder().decode([StoredTitle].self, from: data)
    } catch {
      #if DEBUG
      print("[SeedLoader] Failed to decode seed_titles.json: \(error)")
      #endif
      return []
    }
  }
}

#if DEBUG
extension JSONLibraryStore {
  /// Dev helper: wipe on-disk state (useful during testing)
  func wipeOnDisk() throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
      try fm.removeItem(at: url)
    }
    if fm.fileExists(atPath: backupURL.path) {
      try fm.removeItem(at: backupURL)
    }
  }
}
#endif
