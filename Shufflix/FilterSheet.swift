//
//  FilterSheet.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import SwiftUI

// MARK: - Local Tunables

private enum SearchTuning {
    static let minQueryLength = 2
    static let debounce: Duration = .milliseconds(300)
    static let maxResults = 20
}

// MARK: - FilterSheet

struct FilterSheet: View {
    @EnvironmentObject private var vm: DeckViewModel
    @Environment(\.dismiss) private var dismiss

    // Caller supplies this to open Profile/Settings
    var onOpenSettings: (() -> Void)? = nil

    // Local working copy of filters (mutate VM only on Apply)
    @State private var kind: ContentKind = .all
    @State private var selectedProviders: Set<String> = []
    @State private var selectedGenres: Set<String> = []

    // Search
    @State private var searchText: String = ""
    @State private var results: [TitleItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var lastSearchKey: String = ""
    @State private var selectedItem: TitleItem?

    // Motion namespace for matchedGeometry chips
    @Namespace private var chipNS

    // Derived
    private var hasChanges: Bool {
        kind != vm.filters.kind ||
        selectedProviders != vm.filters.providers ||
        selectedGenres != vm.filters.genres
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(UIColor.systemBackground), Color(UIColor.secondarySystemBackground)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {

                        // MARK: Search Results
                        if shouldShowResultsSection {
                            SectionCard(title: "Results", systemImage: "magnifyingglass") {
                                Group {
                                    if isSearching {
                                        ProgressView("Searching…")
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .padding(.vertical, 8)
                                    } else if let err = searchError {
                                        Label(err, systemImage: "exclamationmark.triangle")
                                            .foregroundStyle(.secondary)
                                    } else if results.isEmpty {
                                        Label("No results", systemImage: "film")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        VStack(spacing: 8) {
                                            ForEach(results) { item in
                                                Button { selectedItem = item } label: {
                                                    ResultRow(item: item)
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel("\(item.name)\(item.year.isEmpty ? "" : ", \(item.year)")")
                                                .accessibilityHint("Opens details")

                                                if item.id != results.last?.id {
                                                    Divider().opacity(0.2)
                                                }
                                            }
                                        }
                                    }
                                }
                                .animation(.easeOut(duration: 0.2), value: isSearching)
                                .animation(.easeOut(duration: 0.2), value: results.count)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // MARK: Content Type
                        SectionCard(title: "Type", systemImage: "square.stack.3d.down.forward") {
                            SegmentedCapsulePicker(selection: $kind, cases: ContentKind.allCases)
                                .accessibilityLabel("Content Type")
                                .onChange(of: kind) { _ in
                                    searchChanged(searchText, immediate: true)
                                }
                        }

                        // MARK: Providers
                        SectionCard(title: "Streaming Services", systemImage: "play.rectangle.on.rectangle") {
                            if vm.availableProviders.isEmpty {
                                Label("No providers available yet", systemImage: "icloud.slash")
                                    .foregroundStyle(.secondary)
                            } else {
                                ChipScroller(
                                    items: vm.availableProviders,
                                    selected: $selectedProviders,
                                    ns: chipNS
                                )
                                if !selectedProviders.isEmpty {
                                    ActiveFilterSummary(
                                        count: selectedProviders.count,
                                        label: "provider\(selectedProviders.count > 1 ? "s" : "")",
                                        clearAll: { withAnimation(.snappy) { selectedProviders.removeAll() } }
                                    )
                                    .padding(.top, 4)
                                }
                            }
                        }

                        // MARK: Genres
                        SectionCard(title: "Genres", systemImage: "sparkles.tv") {
                            if vm.availableGenres.isEmpty {
                                Label("No genres available yet", systemImage: "tray.slash")
                                    .foregroundStyle(.secondary)
                            } else {
                                ChipScroller(
                                    items: vm.availableGenres,
                                    selected: $selectedGenres,
                                    ns: chipNS
                                )
                                if !selectedGenres.isEmpty {
                                    ActiveFilterSummary(
                                        count: selectedGenres.count,
                                        label: "genre\(selectedGenres.count > 1 ? "s" : "")",
                                        clearAll: { withAnimation(.snappy) { selectedGenres.removeAll() } }
                                    )
                                    .padding(.top, 4)
                                }
                            }
                        }

                        Spacer(minLength: 100) // space above sticky bar
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) {
                        Haptics.shared.light()
                        withAnimation(.snappy) {
                            kind = .all
                            selectedProviders.removeAll()
                            selectedGenres.removeAll()
                        }
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityHint("Clear all filters")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button { onOpenSettings?() } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Profile & Settings")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ApplyBar(hasChanges: hasChanges) {
                    Haptics.shared.success()
                    vm.filters = Filters(kind: kind, providers: selectedProviders, genres: selectedGenres)
                    dismiss()
                }
            }
            .searchable(text: $searchText, prompt: "Search movies & shows")
            .onChange(of: searchText) { newValue in
                searchChanged(newValue)
            }
            .onAppear {
                kind = vm.filters.kind
                selectedProviders = vm.filters.providers
                selectedGenres = vm.filters.genres
            }
            .navigationDestination(item: $selectedItem) { item in
                TitleDetailView(item: item)
            }
            .onDisappear { searchTask?.cancel() }
        }
    }

    private var shouldShowResultsSection: Bool {
        isSearching || !results.isEmpty || (!searchText.isEmpty && searchText.count >= SearchTuning.minQueryLength)
    }

    // MARK: - Search (debounced & cancellable)

    private func searchChanged(_ newValue: String, immediate: Bool = false) {
        searchTask?.cancel()
        results.removeAll(keepingCapacity: true)
        searchError = nil

        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= SearchTuning.minQueryLength else {
            isSearching = false
            lastSearchKey = ""
            return
        }

        let key = "\(normalize(trimmed))#\(kind.rawValue)"
        if key == lastSearchKey, !immediate { return }
        lastSearchKey = key

        searchTask = Task { @MainActor in
            isSearching = true
            do {
                if !immediate { try await Task.sleep(for: SearchTuning.debounce) }
                try Task.checkCancellation()

                let scope: TMDBService.MediaTypeFilter = {
                    switch kind {
                    case .all:   return .all
                    case .movie: return .movie
                    case .tv:    return .tv
                    }
                }()

                let hits = try await TMDBService.searchTitles(
                    query: trimmed,
                    type: scope,
                    pageLimit: 1,
                    region: Constants.TMDB.defaultRegion
                )

                results = Array(hits.prefix(SearchTuning.maxResults))
                searchError = nil
            } catch is CancellationError {
                // cancelled silently
            } catch {
                results = []
                searchError = "Couldn’t fetch results."
            }
            isSearching = false
        }
    }

    // MARK: - Helpers

    private func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Components (Self-contained, lightweight, compiler-friendly)

/// Generic rounded "card" section with a title and optional SFSymbol.
private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String?
    @ViewBuilder var content: Content

    init(title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let name = systemImage {
                    Image(systemName: name)
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
        }
    }
}

/// Simple segmented control for an enum that is CaseIterable & RawRepresentable<String>.
private struct SegmentedCapsulePicker<T: Hashable & CaseIterable & RawRepresentable>: View where T.RawValue == String {
    @Binding var selection: T
    let cases: T.AllCases

    init(selection: Binding<T>, cases: T.AllCases) {
        self._selection = selection
        self.cases = cases
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(cases), id: \.self) { value in
                Button {
                    withAnimation(.snappy) { selection = value }
                } label: {
                    Text(value.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            Group {
                                if value == selection {
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.2))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .fill(Color.clear)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(value == selection ? .isSelected : [])
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

/// Minimal result row that only uses fields we know exist (name/year).
private struct ResultRow: View {
    let item: TitleItem

    var body: some View {
        HStack(spacing: 12) {
            // Placeholder poster thumb; avoids external dependencies.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 46, height: 66)
                .overlay(
                    Image(systemName: "film")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                if !item.year.isEmpty {
                    Text(item.year)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Summary line like "3 providers — Clear"
private struct ActiveFilterSummary: View {
    let count: Int
    let label: String
    var clearAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(count) \(label) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                clearAll()
            } label: {
                Text("Clear")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

/// Sticky bottom bar with Apply button.
private struct ApplyBar: View {
    let hasChanges: Bool
    var onApply: () -> Void

    init(hasChanges: Bool, _ onApply: @escaping () -> Void) {
        self.hasChanges = hasChanges
        self.onApply = onApply
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: hasChanges ? "slider.horizontal.3" : "checkmark.circle")
                    .foregroundStyle(hasChanges ? .primary : .secondary)
                Text(hasChanges ? "You have unsaved changes" : "No changes")
                    .foregroundStyle(hasChanges ? .primary : .secondary)
                Spacer()
                Button {
                    onApply()
                } label: {
                    Text("Apply")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(hasChanges ? Color.accentColor : Color.gray.opacity(0.3))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .disabled(!hasChanges)
                .accessibilityHint("Apply selected filters")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial)
        }
    }
}

/// Reusable horizontal chip scroller
private struct ChipScroller: View {
    let items: [String]
    @Binding var selected: Set<String>
    let ns: Namespace.ID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items, id: \.self) { item in
                    SelectChip(
                        title: item,
                        isSelected: selected.contains(item),
                        namespace: ns
                    ) {
                        toggle(item)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func toggle(_ value: String) {
        if selected.contains(value) {
            withAnimation(.snappy) { selected.remove(value) }
        } else {
            withAnimation(.snappy) { selected.insert(value) }
        }
    }
}

/// Simple, fast pill chip with matchedGeometry support.
private struct SelectChip: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.accentColor.opacity(0.2))
                                .matchedGeometryEffect(id: "chip.\(title)", in: namespace, isSource: true)
                        } else {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
