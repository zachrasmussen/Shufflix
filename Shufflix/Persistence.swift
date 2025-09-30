//
//  Persistence.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//Updated 9/27 - 8:40

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

    /// NEW: Last-known deck snapshot for instant launch (option #1).
    var deckSnapshot: [StoredTitle]

    // for future sync/conflict resolution
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
        self.seenIDs     = seenIDs
        self.skippedIDs  = skippedIDs
        self.likedIDs    = likedIDs
        self.liked       = liked
        self.ratings     = ratings
        self.deckSnapshot = deckSnapshot
        self.updatedAt   = updatedAt
        self.version     = version
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

    // debounced writer
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
            // cancel any scheduled write
            pendingWrite?.cancel()

            // Snapshot while on the queue (avoid nested sync on same queue)
            let snapshot = self._state
            let destination = self.url
            let backup = self.backupURL

            let work = DispatchWorkItem {
                do {
                    try JSONLibraryStore.atomicWrite(snapshot, to: destination, backupURL: backup)
                } catch {
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
        // Ensure we don’t write twice (flush any pending)
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
            let dir = base.appendingPathComponent("Shufflix", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: fileProtectionAttributes())
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
            let model = try dec.decode(UserLibrary.self, from: data)
            var migrated = model
            migrateIfNeeded(&migrated)
            // attempt to restore primary from backup
            try? atomicWrite(migrated, to: url, backupURL: backupURL)
            return migrated
        }

        // Nothing on disk → fresh state
        return UserLibrary()
    }

    /// Crash-safe atomic write with backup.
    /// - Writes to a temp file in the same directory, then moves it into place.
    /// - Also refreshes a `.bak` copy after successful commit.
    static func atomicWrite(_ value: UserLibrary, to url: URL, backupURL: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)

        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".tmp")

        // 1) Write atomically to temp file
        try data.write(to: tmp, options: .atomic)

        // 2) Replace destination: remove if exists, then move temp into place
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)

        // 3) Best-effort backup refresh (don’t fail the write if this errors)
        try? data.write(to: backupURL, options: .atomic)

        // 4) Apply protection attributes if missing (iOS only)
        #if os(iOS)
        try? fm.setAttributes(fileProtectionAttributes() ?? [:], ofItemAtPath: url.path)
        #endif
    }

    /// Hook for future schema evolution (no-ops today).
    static func migrateIfNeeded(_ model: inout UserLibrary) {
        // Example:
        // if model.version < 1 { /* transform fields */ model.version = 1 }
        // Keep as placeholder; preserving your current schema.
    }
}

// MARK: - Convenience Mutators

extension JSONLibraryStore {
    func markSeen(_ id: Int) { mutate { $0.seenIDs.insert(id) }; saveDebounced() }
    func markSkipped(_ id: Int) { mutate { $0.skippedIDs.insert(id); $0.seenIDs.insert(id) }; saveDebounced() }
    func unskip(_ id: Int) { mutate { $0.skippedIDs.remove(id) }; saveDebounced() }

    /// Legacy helper: updates only the ID set (no snapshot). Prefer `like(item:)`.
    func like(_ id: Int) { mutate { $0.likedIDs.insert(id); $0.seenIDs.insert(id) }; saveDebounced() }

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
            if let s = stars, s > 0 { $0.ratings[id] = s; $0.seenIDs.insert(id) }
            else { $0.ratings.removeValue(forKey: id) }
        }
        saveDebounced()
    }

    // MARK: - NEW: Deck Snapshot (Option #1)

    /// Save a lightweight snapshot of the deck (cap for size).
    func saveDeckSnapshot(_ items: [TitleItem], cap: Int = 20) {
        let snaps = items.prefix(cap).map { $0.stored }
        mutate { $0.deckSnapshot = Array(snaps) }
        saveDebounced()
    }

    /// Read-only access to the stored snapshot.
    func loadDeckSnapshot() -> [StoredTitle] {
        state.deckSnapshot
    }
}

// MARK: - Option #2: Bundled Seed Loader

/// Reads a bundled `seed_titles.json` (array of `StoredTitle`) to show *instant* cards on the very first launch.
/// Place `seed_titles.json` in the app bundle (e.g., under Resources) matching `StoredTitle` fields.
enum SeedLoader {
    static func loadSeed() -> [StoredTitle] {
        guard let url = Bundle.main.url(forResource: "seed_titles", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return [] }

        do {
            let dec = JSONDecoder()
            return try dec.decode([StoredTitle].self, from: data)
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
