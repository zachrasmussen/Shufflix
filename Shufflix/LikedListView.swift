//
//  LikedListView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Updated 10/2 — single .task: fetch → backfill → hydrate from Supabase

import SwiftUI

// Namespaced keys so values persist across cold launches
private enum PrefsKey {
    static let likedSortKey   = "com.shufflix.liked.sort.key"     // machine value (custom|alpha)
    static let likedMediaType = "com.shufflix.liked.mediaType"
    static let likedGenreName = "com.shufflix.liked.genreName"
    static let likedShowIndex = "com.shufflix.liked.showOrderIndex"

    // Persistent order for "Your List"
    static let likedOrderIDs  = "com.shufflix.liked.order.ids"

    // Legacy (for migration)
    static let legacySortLabel  = "com.shufflix.liked.sort"       // old label-based key
    static let legacySort       = "liked.sort"
    static let legacyMediaType  = "liked.mediaTypeFilter"
    static let legacyGenreName  = "liked.genreFilterName"
}

struct LikedListView: View {
    @EnvironmentObject var vm: DeckViewModel
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Filters & Sort

    enum MediaTypeFilter: String, CaseIterable, Identifiable {
        case all = "All", movie = "Movies", tv = "Shows"
        var id: String { rawValue }
    }

    // Stable machine keys for persistence (no "recent" anymore)
    private enum SortKey: String { case custom, alpha }

    // Friendly display labels
    private func sortDisplayName(_ k: SortKey) -> String {
        switch k {
        case .custom: return "Your List"
        case .alpha:  return "A–Z"
        }
    }

    // Persist user choices (machine values)
    @AppStorage(PrefsKey.likedMediaType) private var mediaTypeRaw: String = MediaTypeFilter.all.rawValue
    @AppStorage(PrefsKey.likedGenreName) private var genreFilterName: String = "All Genres"
    @AppStorage(PrefsKey.likedSortKey)   private var sortKeyRaw: String = SortKey.custom.rawValue
    @AppStorage(PrefsKey.likedShowIndex) private var showOrderIndex: Bool = false

    // Persistent custom order as CSV "id,id,id"
    @AppStorage(PrefsKey.likedOrderIDs) private var likedOrderCSV: String = ""

    // Read-only conveniences
    private var mediaType: MediaTypeFilter { MediaTypeFilter(rawValue: mediaTypeRaw) ?? .all }
    private var sortKey: SortKey { SortKey(rawValue: sortKeyRaw) ?? .custom }

    // Dialog state
    @State private var showShowDialog = false
    @State private var showGenreDialog = false
    @State private var showSortDialog = false
    @State private var didBootstrapPrefs = false
    @State private var didSeedOrder = false

    // MARK: - Derived data

    private var availableGenres: [String] {
        var set = Set<String>()
        for item in vm.liked { for g in item.genres { set.insert(g) } }
        var arr = Array(set)
        arr.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        arr.insert("All Genres", at: 0)
        return arr
    }

    // Parse CSV into [Int] once per render
    private var persistedOrder: [Int] {
        likedOrderCSV.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private var orderIndex: [Int: Int] {
        var dict: [Int: Int] = [:]
        for (i, id) in persistedOrder.enumerated() { dict[id] = i }
        return dict
    }

    private var displayed: [TitleItem] {
        var list: [TitleItem] = vm.liked                  // vm.liked is recency, but we’ll sort as needed
        list = filterByMediaType(list, mediaType: mediaType)
        list = filterByGenre(list, genreName: genreFilterName)
        list = applySort(list, key: sortKey)              // custom uses ledger
        return list
    }

    private func filterByMediaType(_ list: [TitleItem], mediaType: MediaTypeFilter) -> [TitleItem] {
        switch mediaType {
        case .all:   return list
        case .movie: return list.filter { $0.mediaType == .movie }
        case .tv:    return list.filter { $0.mediaType == .tv }
        }
    }

    private func filterByGenre(_ list: [TitleItem], genreName: String) -> [TitleItem] {
        guard genreName != "All Genres" else { return list }
        let target = genreName.lowercased()
        return list.filter { item in
            for g in item.genres { if g.lowercased() == target { return true } }
            return false
        }
    }

    /// Sorting rules:
    /// - Your List (custom): use separate persisted ledger (CSV of IDs). Dragging reorders ONLY the ledger.
    ///   New likes are automatically **prepended to the top** of the ledger.
    /// - A–Z: alphabetical by title.
    private func applySort(_ list: [TitleItem], key: SortKey) -> [TitleItem] {
        switch key {
        case .custom:
            let ids = persistedOrder
            guard !ids.isEmpty else { return list } // if no ledger yet, show recency
            let index = orderIndex
            let (known, unknown) = list.stablePartition { index[$0.id] != nil }
            let knownSorted = known.sorted { (index[$0.id] ?? .max) < (index[$1.id] ?? .max) }
            // Unknowns (not yet in ledger) append after known block, preserving current order
            return knownSorted + unknown

        case .alpha:
            return list.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    // Only allow dragging when there are no filters and custom sort is active
    private var canReorder: Bool {
        sortKey == .custom && mediaType == .all && genreFilterName == "All Genres"
    }

    // MARK: - View

    var body: some View {
        Group {
            if vm.liked.isEmpty {
                EmptyState()
            } else {
                let items = displayed
                List {
                    ForEach(Array(items.enumerated()), id: \.element.id) { (idx, item) in
                        LikedRowLink(item: item,
                                     displayIndex: showOrderIndex ? (idx + 1) : nil)
                        // TRAILING (right→left): Remove (existing behavior)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                vm.removeLiked(item) // remove from library
                                removeFromOrderLedger(id: item.id)
                                Haptics.shared.impact()
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        // LEADING (left→right): Toggle Watched ribbon
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if vm.isWatched(item) {
                                Button {
                                    vm.setWatched(false, for: item)
                                    Haptics.shared.impact()
                                } label: {
                                    Label("Unwatch", systemImage: "eye.slash")
                                }
                                .tint(.gray)
                            } else {
                                Button {
                                    vm.setWatched(true, for: item)
                                    Haptics.shared.impact()
                                } label: {
                                    Label("Watched", systemImage: "checkmark.seal")
                                }
                                .tint(.green)
                            }
                        }
                    }
                    .onMove { src, dst in
                        guard canReorder else { return }
                        // IMPORTANT: do NOT mutate vm.liked here.
                        // We only rewrite the ledger to reflect the user's custom priority.
                        let currentIDs = items.map(\.id) // current displayed order under custom
                        var mutableIDs = currentIDs
                        mutableIDs.move(fromOffsets: src, toOffset: dst)
                        saveOrderLedger(ids: mutableIDs)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            let item = items[i]
                            vm.removeLiked(item)        // remove from library
                            removeFromOrderLedger(id: item.id) // keep custom order clean
                        }
                        normalizeLedgerAgainstCurrentLikes()
                    }
                }
                .listStyle(.insetGrouped)
                .animation(.default, value: vm.liked)
            }
        }
        .navigationTitle("Liked")
        .toolbar { trailingSortToolbar() }
        // Single task: fetch from Supabase → backfill any local-only likes → hydrate metadata
        .task {
            await vm.refreshLikedFromSupabase()

            // Backfill: push local likes that Supabase doesn't know about yet
            let remote = vm.likedFromRemote // non-optional
            let remoteSet = Set(remote.map { "\($0.tmdb_id)-\($0.media)" })
            for item in vm.liked {
                let key = "\(item.id)-\(item.mediaType.rawValue)"
                if !remoteSet.contains(key) {
                    vm.like(tmdbID: Int64(item.id), media: item.mediaType.rawValue)
                }
            }

            await vm.hydrateLikedCacheFromSupabase()
        }
        // Dialogs
        .showDialog(isPresented: $showShowDialog, title: "Show") {
            Button("All")    { mediaTypeRaw = MediaTypeFilter.all.rawValue }
            Button("Movies") { mediaTypeRaw = MediaTypeFilter.movie.rawValue }
            Button("Shows")  { mediaTypeRaw = MediaTypeFilter.tv.rawValue }
        }
        .showDialog(isPresented: $showGenreDialog, title: "Genre") {
            Button("All Genres") { genreFilterName = "All Genres" }
            ForEach(availableGenres.dropFirst(), id: \.self) { g in
                Button(g) { genreFilterName = g }
            }
        }
        .showDialog(isPresented: $showSortDialog, title: "Sort") {
            Button("Your List") { setSort(.custom) }
            Button("A–Z")       { setSort(.alpha) }
        }
        // Persist-hardening + migrations + seeding
        .onAppear {
            bootstrapPrefsIfNeeded()
            seedOrderIfNeeded()
        }
        .onChange(of: vm.liked) { _ in
            // Keep ledger in sync when likes change externally (add/remove from detail, etc.)
            normalizeLedgerAgainstCurrentLikes()
        }
        .onChange(of: sortKeyRaw)      { UserDefaults.standard.set($0, forKey: PrefsKey.likedSortKey) }
        .onChange(of: mediaTypeRaw)    { UserDefaults.standard.set($0, forKey: PrefsKey.likedMediaType) }
        .onChange(of: genreFilterName) { UserDefaults.standard.set($0, forKey: PrefsKey.likedGenreName) }
        .onChange(of: showOrderIndex)  { UserDefaults.standard.set($0, forKey: PrefsKey.likedShowIndex) }
        .onChange(of: scenePhase) { phase in
            if phase == .background { UserDefaults.standard.synchronize() }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func trailingSortToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if !vm.liked.isEmpty {
                Menu {
                    Button { showShowDialog = true }  label: { chevronRow("\(mediaType.rawValue)") }
                    Button { showGenreDialog = true } label: { chevronRow("\(genreFilterName)") }
                    Button { showSortDialog = true }  label: { chevronRow("\(sortDisplayName(sortKey))") }

                    Divider()
                    Toggle(isOn: $showOrderIndex) {
                        HStack {
                            Image(systemName: "number")
                            Text("Show Order Numbers")
                        }
                    }

                    Section {
                        Button { resetPrefs() } label: {
                            Label("Reset Filters", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down.square")
                }
                .accessibilityLabel("Sort and filter liked list")
            }
        }
    }

    // MARK: - Helpers

    private func setSort(_ key: SortKey) {
        sortKeyRaw = key.rawValue
    }

    /// Initialize or tidy the ledger:
    /// - If empty, seed with current Recents order (vm.liked IDs).
    /// - Else, drop IDs that no longer exist and **prepend** newly liked IDs to the top.
    private func seedOrderIfNeeded() {
        guard !didSeedOrder else { return }
        didSeedOrder = true
        normalizeLedgerAgainstCurrentLikes(seedIfEmpty: true)
    }

    private func normalizeLedgerAgainstCurrentLikes(seedIfEmpty: Bool = false) {
        let currentIDs = vm.liked.map(\.id) // newest-first baseline
        var ledger = persistedOrder

        if ledger.isEmpty, seedIfEmpty {
            saveOrderLedger(ids: currentIDs) // start with newest-first
            return
        }

        // Remove any IDs that are no longer liked
        let currentSet = Set(currentIDs)
        ledger.removeAll(where: { !currentSet.contains($0) })

        // Prepend any newly liked IDs that aren't in the ledger yet (newest should float to TOP)
        let newOnes = currentIDs.filter { !ledger.contains($0) }
        if !newOnes.isEmpty {
            ledger = newOnes + ledger
        }

        // Only write if changed
        if ledger != persistedOrder { saveOrderLedger(ids: ledger) }
    }

    private func saveOrderLedger(ids: [Int]) {
        likedOrderCSV = ids.map(String.init).joined(separator: ",")
        UserDefaults.standard.set(likedOrderCSV, forKey: PrefsKey.likedOrderIDs)
    }

    private func removeFromOrderLedger(id: Int) {
        let filtered = persistedOrder.filter { $0 != id }
        saveOrderLedger(ids: filtered)
    }

    private func bootstrapPrefsIfNeeded() {
        guard !didBootstrapPrefs else { return }
        didBootstrapPrefs = true
        let d = UserDefaults.standard

        // If machine-key is missing, try to migrate from old label keys.
        // Old "Recents" becomes "Your List" (custom) since Recents no longer exists.
        if d.object(forKey: PrefsKey.likedSortKey) == nil {
            if let label = d.string(forKey: PrefsKey.legacySortLabel) ?? d.string(forKey: PrefsKey.legacySort) {
                let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized.contains("list") || normalized == "custom" || normalized.contains("recent") {
                    sortKeyRaw = SortKey.custom.rawValue
                } else if normalized.contains("a–z") || normalized.contains("a-z") || normalized == "alpha" {
                    sortKeyRaw = SortKey.alpha.rawValue
                } else {
                    sortKeyRaw = SortKey.custom.rawValue
                }
            } else {
                sortKeyRaw = SortKey.custom.rawValue
            }
        }

        // Migrate old mediaType/genre if new ones missing
        if d.object(forKey: PrefsKey.likedMediaType) == nil,
           let legacy = d.string(forKey: PrefsKey.legacyMediaType) { mediaTypeRaw = legacy }
        if d.object(forKey: PrefsKey.likedGenreName) == nil,
           let legacy = d.string(forKey: PrefsKey.legacyGenreName) { genreFilterName = legacy }
    }

    private func resetPrefs() {
        mediaTypeRaw    = MediaTypeFilter.all.rawValue
        genreFilterName = "All Genres"
        sortKeyRaw      = SortKey.custom.rawValue   // default to Your List
        showOrderIndex  = false
        // Keep the custom order ledger so a user’s manual order persists.
    }

    @ViewBuilder
    private func chevronRow(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
        }
    }
}

// MARK: - Small view pieces

private struct LikedRowLink: View {
    @EnvironmentObject var vm: DeckViewModel
    let item: TitleItem
    let displayIndex: Int?

    var body: some View {
        NavigationLink {
            TitleDetailView(item: item)
        } label: {
            Row(item: item,
                isWatched: vm.isWatched(item),
                displayIndex: displayIndex)
        }
        // NOTE: Swipe actions are attached on the List row in parent (LikedListView)
    }
}

private struct Row: View {
    @AppStorage(PrefsKey.likedShowIndex) private var showOrderIndex: Bool = false
    let item: TitleItem
    let isWatched: Bool
    let displayIndex: Int?

    var body: some View {
        HStack(spacing: 12) {
            if showOrderIndex, let idx = displayIndex {
                Text("\(idx)")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .accessibilityHidden(true)
            }

            // Poster with WATCHED ribbon overlay
            ZStack(alignment: .topLeading) {
                PosterThumb(url: item.posterURL)
                if isWatched {
                    WatchedRibbon()
                        .offset(x: -6, y: 6)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).lineLimit(2)
                HStack(spacing: 8) {
                    if !item.year.isEmpty { Text(item.year) }
                    if let g = item.genres.first { Text("• \(g)") }
                }
                .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)\(item.year.isEmpty ? "" : ", \(item.year)")\(isWatched ? ", watched" : "")")
        .accessibilityHint("Opens details")
    }
}

private struct PosterThumb: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill().transition(.opacity)
            case .empty: Rectangle().fill(Color.secondary.opacity(0.15)).overlay(ProgressView().controlSize(.small))
            case .failure: Rectangle().fill(Color.secondary.opacity(0.15)).overlay(Image(systemName: "film").imageScale(.large))
            @unknown default: Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: 60, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

// MARK: - Watched ribbon

private struct WatchedRibbon: View {
    var body: some View {
        Text("WATCHED")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .kerning(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.green.opacity(0.88)))
            .foregroundColor(.white)
            .rotationEffect(.degrees(-12))
            .shadow(radius: 1, x: 0, y: 1)
    }
}

// MARK: - Empty State

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No likes yet").font(.title3.weight(.semibold))
            Text("Swipe right on titles to add them here.")
                .foregroundColor(.secondary).font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Lightweight modifiers

private extension View {
    func showDialog<Content: View>(isPresented: Binding<Bool>, title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        self.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible, actions: content)
    }
}

// MARK: - Small utility

private extension Array {
    /// Stable partition that preserves relative order in each bucket.
    func stablePartition(by belongsInFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        first.reserveCapacity(self.count)
        second.reserveCapacity(self.count)
        for el in self {
            if belongsInFirst(el) { first.append(el) } else { second.append(el) }
        }
        return (first, second)
    }
}
