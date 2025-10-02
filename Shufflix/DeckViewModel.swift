//
//  DeckViewModel.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Refactored:
//

import Foundation
import SwiftUI
import Combine
import Supabase

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
    
    // Remote (Supabase) — temporary sink for testing/inspection
    @Published var likedFromRemote: [UserTitle] = []
    @Published var likedCache: [TitleCache] = []

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

    // ✅ Watched (persisted via UserDefaults; used only by LikedListView)
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

    // Computed: everything to exclude from the deck (recomputed on demand)
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

        let st = store.state
        self.ratings     = st.ratings
        self.seenIDs     = st.seenIDs
        self.skippedIDs  = st.skippedIDs
        self.liked       = st.liked.map { $0.asTitleItem() }
        self.skipped     = [] // session-only history

        // Restore watched from UserDefaults
        loadWatched()

        // Prewarm haptics so first interaction feels instant
        Haptics.shared.prewarm()

        // Initial fetch (cancellable)
        refreshDeck()
    }

    deinit { loadTask?.cancel() }

    // MARK: - Public getters

    func currentDeck() -> [TitleItem] { deck }
    func isLiked(_ item: TitleItem) -> Bool { liked.contains(where: { $0.id == item.id }) }
    func rating(for item: TitleItem) -> Int? { ratings[item.id] }

    // MARK: - Watched helpers (for LikedListView)

    func isWatched(_ item: TitleItem) -> Bool {
        watchedIDs.contains(item.id)
    }

    func setWatched(_ watched: Bool, for item: TitleItem) {
        if watched { watchedIDs.insert(item.id) } else { watchedIDs.remove(item.id) }
        saveWatched()
    }

    func toggleWatched(for item: TitleItem) {
        setWatched(!isWatched(item), for: item)
    }

    func setWatched(_ watched: Bool, for items: [TitleItem]) {
        if watched {
            watchedIDs.formUnion(items.map(\.id))
        } else {
            watchedIDs.subtract(items.map(\.id))
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
        snapshotDeck()
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
        snapshotDeck()
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
        snapshotDeck()
        prefetchIfNeeded()

        // ---- NEW: Persist to Supabase in the background (non-blocking)
        Task { [tmdbID = Int64(item.id), media = item.mediaType.rawValue] in
            if didLike {
                self.like(tmdbID: tmdbID, media: media)   // defined in DeckViewModel+Supabase
            } else {
                self.skip(tmdbID: tmdbID, media: media)   // defined in DeckViewModel+Supabase
            }
        }
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
        snapshotDeck()
    }

    // MARK: - Liked management (reorder / remove)

    func moveLiked(from sourceOffsets: IndexSet, to destination: Int) {
        liked.move(fromOffsets: sourceOffsets, toOffset: destination)
        // Persist custom order later if needed
    }

    func removeLiked(at offsets: IndexSet) {
        for idx in offsets {
            store.unlike(liked[idx].id)
        }
        liked.remove(atOffsets: offsets)
        prefilterDeckAfterChange()
        snapshotDeck()
    }

    func removeLiked(_ item: TitleItem) {
        if let idx = liked.firstIndex(of: item) {
            store.unlike(item.id)
            liked.remove(at: idx)
            prefilterDeckAfterChange()
            snapshotDeck()
        }
    }

    // MARK: - Networking (load / paging / cancellation)

    func refreshDeck() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            errorMessage = nil
            isLoading = true
            isPrimed = false
            pinnedTopID = nil
            resetPaging()
            deck.removeAll(keepingCapacity: true)
            source.removeAll(keepingCapacity: true)
            await loadMoreInternal(minimumCount: prefetchThreshold * 2)
            isLoading = false
            snapshotDeck()
        }
    }

    func loadMore() async {
        await loadMoreInternal(minimumCount: prefetchThreshold)
    }

    private func resetPaging() {
        nextPage = Dictionary(uniqueKeysWithValues: Feed.allCases.map { ($0, 1) })
        feedIndex = 0
    }

    /// Feeds that can actually contribute given the current `filters.kind`
    private var allowedFeeds: [Feed] {
        switch filters.kind {
        case .all:
            return Array(Feed.allCases)
        case .movie:
            return Feed.allCases.filter { f in
                switch f {
                case .popularTV, .topTV, .discoverTV, .trendingDay, .trendingWeek: return f == .trendingDay || f == .trendingWeek ? true : false
                default: return true
                }
            }
        case .tv:
            return Feed.allCases.filter { f in
                switch f {
                case .popularMovie, .topMovie, .discoverMovie, .trendingDay, .trendingWeek: return f == .trendingDay || f == .trendingWeek ? true : false
                default: return true
                }
            }
        }
    }

    private func loadMoreInternal(minimumCount: Int) async {
        guard !Task.isCancelled else { return }

        var totalAppended = 0
        var protection = 0
        let feeds = allowedFeeds.isEmpty ? Feed.allCases : allowedFeeds

        while totalAppended < minimumCount,
              protection < feeds.count * 3,
              !Task.isCancelled {
            protection &+= 1

            do {
                let batch = try await fetchNextBatch(from: feeds)
                let appended = handleIncomingBatch(batch)
                totalAppended &+= appended
                if appended == 0 { continue }
            } catch is CancellationError {
                return
            } catch {
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
        }
    }

    private func fetchNextBatch(from feeds: [Feed]) async throws -> [TitleItem] {
        // rotate through allowed feeds
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
                guard filters.kind != .tv else { nextPage[feed] = page + 1; continue }
                media = try await TMDBService.popular(.movie, page: page)
            case .popularTV:
                guard filters.kind != .movie else { nextPage[feed] = page + 1; continue }
                media = try await TMDBService.popular(.tv, page: page)
            case .topMovie:
                guard filters.kind != .tv else { nextPage[feed] = page + 1; continue }
                media = try await TMDBService.topRated(.movie, page: page)
            case .topTV:
                guard filters.kind != .movie else { nextPage[feed] = page + 1; continue }
                media = try await TMDBService.topRated(.tv, page: page)
            case .discoverMovie:
                guard filters.kind != .tv else { nextPage[feed] = page + 1; continue }
                let genreIDs = filters.genres.compactMap { reverseGenreMap[$0] }
                media = try await TMDBService.discover(.movie, page: page, genres: genreIDs)
            case .discoverTV:
                guard filters.kind != .movie else { nextPage[feed] = page + 1; continue }
                let genreIDs = filters.genres.compactMap { reverseGenreMap[$0] }
                media = try await TMDBService.discover(.tv, page: page, genres: genreIDs)
            }

            nextPage[feed] = page + 1

            let mapped = await TMDBService.mapToTitleItems(media)
            // Exclude blocked immediately
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
            // If we already have a deck but weren’t marked primed yet, do it now.
            if !deck.isEmpty && !isPrimed {
                isPrimed = true
                if pinnedTopID == nil { pinnedTopID = deck.last?.id }
            }
            return 0
        }

        // 1) Update master source and derived filters once
        source = (source + additions).unique(by: \.id)
        rebuildAvailableFilters(from: source)

        // 2) Exclude items we shouldn't show OR are already on deck
        let deckIDs = Set(deck.lazy.map(\.id))
        let cleaned = additions.filter { !blockedIDs.contains($0.id) && !deckIDs.contains($0.id) }

        // 3) Keep only those that match current filters + stable order from source
        let poolIDs = Set(filteredPoolIDs())
        let toQueue = cleaned.filter { poolIDs.contains($0.id) }
        guard !toQueue.isEmpty else {
            if !deck.isEmpty && !isPrimed {
                isPrimed = true
                if pinnedTopID == nil { pinnedTopID = deck.last?.id }
            }
            return 0
        }

        // Insert new cards at the bottom (index 0) to avoid changing the current top.
        deck.insert(contentsOf: toQueue, at: 0)

        // Mark primed & pin the current top (the last element) if this is first content
        if !isPrimed, !deck.isEmpty {
            isPrimed = true
            if pinnedTopID == nil { pinnedTopID = deck.last?.id }
        }

        snapshotDeck()
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
            snapshotDeck()
        } catch {
            #if DEBUG
            print("[Deck] similar fetch error:", error)
            #endif
        }
    }

    // MARK: - Filters

    private func rebuildAvailableFilters(from items: [TitleItem]) {
        // Compute using Sets; then sort once for stable UI
        let providers = Set(items.lazy.flatMap { $0.providers.lazy.map(\.name) })
        let genres    = Set(items.lazy.flatMap { $0.genres })

        availableProviders = Array(providers).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        availableGenres    = Array(genres).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        snapshotDeck()
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
            // Case-insensitive provider matching
            let wanted = Set(filters.providers.map { $0.lowercased() })
            pool = pool.filter {
                !$0.providers.isEmpty &&
                !$0.providers.lazy.map({ $0.name.lowercased() }).filter({ wanted.contains($0) }).isEmpty
            }
        }

        if !filters.genres.isEmpty {
            let wanted = Set(filters.genres.map { $0.lowercased() })
            pool = pool.filter {
                !$0.genres.isEmpty &&
                !$0.genres.lazy.map({ $0.lowercased() }).filter({ wanted.contains($0) }).isEmpty
            }
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

    /// Persist a lightweight snapshot of the current deck for instant cold-start.
    private func snapshotDeck() {
        guard !deck.isEmpty else { return }
        store.saveDeckSnapshot(deck)
    }

    // MARK: - App lifecycle

    /// Call this from your root view on .background / .inactive
    func flush() { try? store.saveNow() }

    // MARK: - Supabase integration (fetch liked)

    /// Fetches liked rows from Supabase for the current env.
    func refreshLikedFromSupabase() async {
        do {
            let rows = try await SupabaseService().fetchLiked()
            self.likedFromRemote = rows
            print("Supabase liked fetched:", rows.count)
        } catch {
            self.errorMessage = (error as NSError).localizedDescription
            print("refreshLikedFromSupabase error:", error)
        }
    }
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
