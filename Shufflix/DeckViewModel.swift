//
//  DeckViewModel.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Updated 9/28 - 7:45
//

import Foundation
import SwiftUI
import Combine

// MARK: - Types

enum ContentKind: String, CaseIterable {
    case all = "All"
    case movie = "Movies"
    case tv = "Shows"
}

private enum Feed: CaseIterable {
    case trendingWeek, trendingDay, popularMovie, popularTV, topMovie, topTV, discoverMovie, discoverTV
}

struct Filters: Equatable {
    var kind: ContentKind = .all
    var providers: Set<String> = []
    var genres: Set<String> = []
}

// MARK: - ViewModel

@MainActor
final class DeckViewModel: ObservableObject {
    // Data (UI-facing)
    @Published private(set) var deck: [TitleItem] = []
    @Published private(set) var liked: [TitleItem] = []     // persisted via store (snapshots)
    @Published private(set) var skipped: [TitleItem] = []   // UI-only session history (IDs persist via store)

    // Filters
    @Published var filters = Filters() {
        didSet { applyFilters() }
    }
    @Published private(set) var availableProviders: [String] = []
    @Published private(set) var availableGenres: [String] = []

    // UI/State
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    // ⚙️ Priming + pinning
    @Published private(set) var isPrimed = false
    private var pinnedTopID: Int?

    // Ratings (persisted via store; mirrored for fast UI lookup)
    @Published private(set) var ratings: [Int: Int] = [:]

    // ✅ NEW: Watched (persisted via UserDefaults; used only by LikedListView)
    @Published private(set) var watchedIDs: Set<Int> = []
    private let watchedDefaultsKey = "com.shufflix.library.watchedIDs.v1"

    // Local state (mirrors persisted pieces for fast checks)
    private var seenIDs: Set<Int> = []
    private var skippedIDs: Set<Int> = []

    /// Backing pool of fetched items (filtered into `deck`)
    private var source: [TitleItem] = []

    // Persistence
    private let store: JSONLibraryStore

    // Feed paging (internal)
    private var nextPage: [Feed: Int] = Dictionary(uniqueKeysWithValues: Feed.allCases.map { ($0, 1) })
    private var feedIndex: Int = 0

    // Reverse genre lookup (e.g., "Action" -> 28)
    private let reverseGenreMap: [String: Int] = Dictionary(uniqueKeysWithValues: Constants.genreMap.map { ($1, $0) })

    // Prefetch
    private let prefetchThreshold = 6

    // Cancellation
    private var loadTask: Task<Void, Never>?

    // Computed: everything to exclude from the deck
    // NOTE: We do NOT exclude watched here; watched is only a ribbon on LikedListView.
    private var blockedIDs: Set<Int> {
        var s = seenIDs
        s.formUnion(skippedIDs)
        s.formUnion(liked.lazy.map(\.id))
        s.formUnion(skipped.lazy.map(\.id))
        return s
    }

    // MARK: - Init

    init(store: JSONLibraryStore = JSONLibraryStore()) {
        self.store = store

        // Restore persisted state
        let st = store.state
        self.ratings     = st.ratings
        self.seenIDs     = st.seenIDs
        self.skippedIDs  = st.skippedIDs
        self.liked       = st.liked.map { $0.asTitleItem() }
        self.skipped     = [] // session-only history

        // Restore watched from UserDefaults (independent of ratings)
        loadWatched()

        // Initial fetch (cancellable)
        refreshDeck()
    }

    deinit { loadTask?.cancel() }

    // MARK: - Public getters

    func currentDeck() -> [TitleItem] { deck }
    func isLiked(_ item: TitleItem) -> Bool { liked.contains(where: { $0.id == item.id }) }
    func rating(for item: TitleItem) -> Int? { ratings[item.id] }

    // MARK: - NEW: Watched helpers (for LikedListView)

    func isWatched(_ item: TitleItem) -> Bool {
        watchedIDs.contains(item.id)
    }

    func setWatched(_ watched: Bool, for item: TitleItem) {
        if watched {
            watchedIDs.insert(item.id)
        } else {
            watchedIDs.remove(item.id)
        }
        saveWatched()
    }

    func toggleWatched(for item: TitleItem) {
        setWatched(!isWatched(item), for: item)
    }

    /// Bulk helper (used by optional menu actions in LikedListView)
    func setWatched(_ watched: Bool, for items: [TitleItem]) {
        if watched {
            watchedIDs.formUnion(items.map { $0.id })
        } else {
            watchedIDs.subtract(items.map { $0.id })
        }
        saveWatched()
    }

    // MARK: - Like / Skip / Rate

    func likeFromDetail(_ item: TitleItem) {
        pinnedTopID = nil

        guard !isLiked(item) else { return }
        removeFromDeckIfPresent(item.id)

        liked.insert(item, at: 0)
        seenIDs.insert(item.id)

        store.like(item: item)
        Haptics.shared.impact()
        prefetchIfNeeded()
    }

    func toggleLike(_ item: TitleItem) {
        pinnedTopID = nil

        if let idx = liked.firstIndex(where: { $0.id == item.id }) {
            liked.remove(at: idx)
            store.unlike(item.id)
        } else {
            liked.insert(item, at: 0)
            seenIDs.insert(item.id)
            store.like(item: item)
        }
        Haptics.shared.impact()
    }

    func swipe(_ item: TitleItem, liked didLike: Bool) {
        pinnedTopID = nil

        removeFromDeckIfPresent(item.id)

        if didLike {
            if !isLiked(item) {
                liked.insert(item, at: 0)
                store.like(item: item) // persist snapshot
            }
        } else {
            skipped.append(item)          // session history
            skippedIDs.insert(item.id)    // mirror persistable ID
            store.markSkipped(item.id)    // persist (also marks seen)
        }

        seenIDs.insert(item.id)
        Haptics.shared.impact()
        prefilterDeckAfterChange()
        prefetchIfNeeded()
    }

    func setRating(for item: TitleItem, to stars: Int) {
        let clamped = max(0, min(5, stars))
        if clamped > 0 {
            ratings[item.id] = clamped
            store.rate(item.id, stars: clamped)
        } else {
            ratings.removeValue(forKey: item.id)
            store.rate(item.id, stars: nil)
        }

        if clamped >= 5 {
            Task { await injectSimilar(for: item) }
        }
    }

    // MARK: - Liked management (reorder / remove)

    func moveLiked(from sourceOffsets: IndexSet, to destination: Int) {
        liked.move(fromOffsets: sourceOffsets, toOffset: destination)
        // If you later persist order, do it here.
    }

    func removeLiked(at offsets: IndexSet) {
        for idx in offsets {
            let id = liked[idx].id
            store.unlike(id)
        }
        liked.remove(atOffsets: offsets)
        prefilterDeckAfterChange()
    }

    func removeLiked(_ item: TitleItem) {
        if let idx = liked.firstIndex(of: item) {
            liked.remove(at: idx)
            store.unlike(item.id)
            prefilterDeckAfterChange()
        }
    }

    // MARK: - Networking (load / paging / cancellation)

    func refreshDeck() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            self.errorMessage = nil
            self.isLoading = true
            self.isPrimed = false
            self.pinnedTopID = nil
            self.resetPaging()
            self.deck.removeAll(keepingCapacity: true)
            await self.loadMoreInternal(minimumCount: self.prefetchThreshold * 2)
            self.isLoading = false
        }
    }

    func loadMore() async {
        await loadMoreInternal(minimumCount: prefetchThreshold)
    }

    private func resetPaging() {
        nextPage = Dictionary(uniqueKeysWithValues: Feed.allCases.map { ($0, 1) })
        feedIndex = 0
    }

    private func loadMoreInternal(minimumCount: Int) async {
        guard !Task.isCancelled else { return }

        var totalAppended = 0
        var protection = 0

        while totalAppended < minimumCount,
              protection < Feed.allCases.count * 3,
              !Task.isCancelled {
            protection += 1

            do {
                let batch = try await fetchNextBatch()
                let appended = handleIncomingBatch(batch)
                totalAppended &+= appended

                if appended == 0 {
                    continue
                }
            } catch {
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
        }
    }

    private func fetchNextBatch() async throws -> [TitleItem] {
        let feeds = Feed.allCases

        for _ in 0..<feeds.count {
            let feed = feeds[feedIndex % feeds.count]
            feedIndex &+= 1

            let page = nextPage[feed] ?? 1
            let media: [TMDBService.Media]

            switch feed {
            case .trendingWeek:
                media = try await TMDBService.trending(window: "week", page: page)
            case .trendingDay:
                media = try await TMDBService.trending(window: "day", page: page)
            case .popularMovie:
                media = try await TMDBService.popular(.movie, page: page)
            case .popularTV:
                media = try await TMDBService.popular(.tv, page: page)
            case .topMovie:
                media = try await TMDBService.topRated(.movie, page: page)
            case .topTV:
                media = try await TMDBService.topRated(.tv, page: page)
            case .discoverMovie:
                let genreIDs = filters.genres.compactMap { reverseGenreMap[$0] }
                media = try await TMDBService.discover(.movie, page: page, genres: genreIDs)
            case .discoverTV:
                let genreIDs = filters.genres.compactMap { reverseGenreMap[$0] }
                media = try await TMDBService.discover(.tv, page: page, genres: genreIDs)
            }

            nextPage[feed] = page + 1

            let mapped = await TMDBService.mapToTitleItems(media)
            let fresh = mapped.filter { !blockedIDs.contains($0.id) }
            if !fresh.isEmpty { return fresh.shuffled() }
        }
        return []
    }

    /// Handles items and returns how many were appended to the deck.
    /// Respects `pinnedTopID` so the initially-visible card never changes until the user acts.
    @discardableResult
    private func handleIncomingBatch(_ additions: [TitleItem]) -> Int {
        guard !additions.isEmpty else {
            if !deck.isEmpty && !isPrimed {
                isPrimed = true
                if pinnedTopID == nil { pinnedTopID = deck.last?.id }
            }
            return 0
        }

        // Update master source and derived filters once
        source = (source + additions).unique(by: \.id)
        rebuildAvailableFilters(from: source)

        // Exclude items we shouldn't show OR are already on deck
        let deckIDs = Set(deck.lazy.map(\.id))
        let cleaned = additions.filter { !blockedIDs.contains($0.id) && !deckIDs.contains($0.id) }

        // Keep only those that match current filters + stable order from source
        let poolIDs = Set(filteredPoolIDs())
        let toQueue = cleaned.filter { poolIDs.contains($0.id) }
        guard !toQueue.isEmpty else {
            if !deck.isEmpty && !isPrimed {
                isPrimed = true
                if pinnedTopID == nil { pinnedTopID = deck.last?.id }
            }
            return 0
        }

        // Insert new cards at the **bottom** (index 0) to avoid changing the current top.
        deck.insert(contentsOf: toQueue, at: 0)

        // First time we have something → mark primed & pin the current top
        if !isPrimed, !deck.isEmpty {
            isPrimed = true
            if pinnedTopID == nil { pinnedTopID = deck.last?.id }
        }

        return toQueue.count
    }

    private func injectSimilar(for item: TitleItem) async {
        do {
            let similar = try await TMDBService.fetchSimilar(for: item.id, mediaType: item.mediaType)

            // Seen universe (avoid resurfacing)
            var seen = Set((deck + liked + skipped).lazy.map(\.id))
            seen.formUnion(seenIDs)
            seen.formUnion(skippedIDs)

            let newOnes = similar.filter { !seen.contains($0.id) }
            let top = Array(newOnes.prefix(10))
            guard !top.isEmpty else { return }

            // Update `source` once
            source = (source + top).unique(by: \.id)
            rebuildAvailableFilters(from: source)

            let poolIDs = Set(filteredPoolIDs())
            let toQueue = top.filter { poolIDs.contains($0.id) }
            guard !toQueue.isEmpty else { return }

            withAnimation {
                deck.insert(contentsOf: toQueue, at: 0)
            }
        } catch {
            #if DEBUG
            print("similar fetch error:", error)
            #endif
        }
    }

    // MARK: - Filters

    private func rebuildAvailableFilters(from items: [TitleItem]) {
        // Compute using Sets; then sort once for stable UI
        let providers = Set(items.lazy.flatMap { $0.providers.lazy.map(\.name) })
        let genres    = Set(items.lazy.flatMap { $0.genres })

        availableProviders = Array(providers).sorted()
        availableGenres    = Array(genres).sorted()
    }

    /// Applies current `filters` to the visible deck.
    /// Keeps the pinned top card (if any) even if it no longer matches—until first user action unpins.
    func applyFilters() {
        let poolSet = Set(filteredPoolIDs())
        let pinned = pinnedTopID

        // 1) Remove cards that no longer match filters (but keep pinned top if present)
        deck = deck.filter { item in
            if let pinned, item.id == pinned { return true }
            return poolSet.contains(item.id)
        }

        // 2) Add any missing items (from the pool) at the bottom (index 0)
        let currentIDs = Set(deck.lazy.map(\.id))
        let toAddIDs = source.lazy.map(\.id).filter { poolSet.contains($0) && !currentIDs.contains($0) }
        guard !toAddIDs.isEmpty else { return }

        let idToItem = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        let toAddItems = toAddIDs.compactMap { idToItem[$0] }

        deck.insert(contentsOf: toAddItems, at: 0)

        prefetchIfNeeded()
    }

    /// Filtered pool as IDs, in a stable order from `source`
    private func filteredPoolIDs() -> [Int] {
        var pool = source.filter { s in
            !( liked.contains(where: { $0.id == s.id })
               || skipped.contains(where: { $0.id == s.id })
               || seenIDs.contains(s.id)
               || skippedIDs.contains(s.id) )
        }

        switch filters.kind {
        case .movie:
            pool = pool.filter { $0.mediaType == .movie }
        case .tv:
            pool = pool.filter { $0.mediaType == .tv }
        case .all:
            break
        }

        if !filters.providers.isEmpty {
            pool = pool.filter { !Set($0.providers.lazy.map(\.name)).intersection(filters.providers).isEmpty }
        }

        if !filters.genres.isEmpty {
            pool = pool.filter { !Set($0.genres).intersection(filters.genres).isEmpty }
        }

        return pool.map(\.id)
    }

    // MARK: - Utilities

    private func removeFromDeckIfPresent(_ id: Int) {
        if let idx = deck.firstIndex(where: { $0.id == id }) {
            deck.remove(at: idx)
        }
    }

    private func prefilterDeckAfterChange() {
        if deck.isEmpty { return }
        let blocked = blockedIDs
        deck.removeAll(where: { blocked.contains($0.id) })
    }

    private func prefetchIfNeeded() {
        guard deck.count < prefetchThreshold else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadMoreInternal(minimumCount: self.prefetchThreshold)
        }
    }

    // MARK: - App lifecycle

    /// Call this from your root view on .background / .inactive
    func flush() { try? store.saveNow() }
}

// MARK: - Watched persistence

private extension DeckViewModel {
    func loadWatched() {
        let ids = UserDefaults.standard.array(forKey: watchedDefaultsKey) as? [Int] ?? []
        watchedIDs = Set(ids)
    }

    func saveWatched() {
        UserDefaults.standard.set(Array(watchedIDs), forKey: watchedDefaultsKey)
    }
}

// MARK: - Utilities

extension Array {
    /// Returns a new array keeping the first occurrence for each unique key.
    func unique<ID: Hashable>(by key: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        var out: [Element] = []
        out.reserveCapacity(self.count)
        for el in self {
            let k = el[keyPath: key]
            if seen.insert(k).inserted { out.append(el) }
        }
        return out
    }
}
