//
//  FilterSheet.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//Updated 9/27 - 7:45

import SwiftUI
import UIKit

private enum SearchTuning {
    static let minQueryLength = 2
    static let debounceNanos: UInt64 = 300_000_000 // 300ms
    static let maxResults = 20
}

struct FilterSheet: View {
    @EnvironmentObject var vm: DeckViewModel
    @Environment(\.dismiss) private var dismiss

    // Local working copy (mutate VM only on Apply)
    @State private var kind: ContentKind = .all
    @State private var selectedProviders: Set<String> = []
    @State private var selectedGenres: Set<String> = []

    // Search
    @State private var searchText: String = ""
    @State private var results: [TitleItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var lastSearchKey: String = ""   // (trimmed query + kind) for dedup
    @State private var selectedItem: TitleItem?

    // Motion
    @Namespace private var chipNS

    // Derived
    private var hasChanges: Bool {
        (kind != vm.filters.kind) ||
        (selectedProviders != vm.filters.providers) ||
        (selectedGenres != vm.filters.genres)
    }

    // Simpler bg to avoid type-check slowdowns
    private var bgGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [Color(UIColor.systemBackground), Color(UIColor.secondarySystemBackground)]),
            startPoint: .top, endPoint: .bottom
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                bgGradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {

                        // MARK: Search Results
                        if shouldShowResultsSection {
                            SectionCard(title: "Results", systemImage: "magnifyingglass") {
                                if isSearching {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                        Text("Searching…").foregroundStyle(.secondary)
                                    }
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
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .animation(.easeOut(duration: 0.22), value: results)
                            .animation(.easeOut(duration: 0.22), value: isSearching)
                        }

                        // MARK: Content Type
                        SectionCard(title: "Type", systemImage: "square.stack.3d.down.forward") {
                            SegmentedCapsulePicker(selection: $kind, cases: ContentKind.allCases) { k in
                                Text(k.rawValue)
                            }
                            .accessibilityLabel("Content Type")
                            .onChange(of: kind) { _ in
                                // Re-run search immediately for tighter scope
                                searchChanged(searchText, immediate: true)
                            }
                        }

                        // MARK: Providers
                        SectionCard(title: "Streaming Services", systemImage: "play.rectangle.on.rectangle") {
                            if vm.availableProviders.isEmpty {
                                Label("No providers available yet", systemImage: "icloud.slash")
                                    .foregroundStyle(.secondary)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(vm.availableProviders, id: \.self) { name in
                                            SelectChip(
                                                title: name,
                                                isSelected: selectedProviders.contains(name),
                                                namespace: chipNS
                                            ) {
                                                toggle(name, in: &selectedProviders)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }

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
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(vm.availableGenres, id: \.self) { g in
                                            SelectChip(
                                                title: g,
                                                isSelected: selectedGenres.contains(g),
                                                namespace: chipNS
                                            ) {
                                                toggle(g, in: &selectedGenres)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }

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

                        Spacer(minLength: 100) // room above sticky bar
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
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            }
            // Sticky Apply bar
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ApplyBar(hasChanges: hasChanges) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    // Single assignment triggers DeckViewModel.didSet → applyFilters()
                    vm.filters = Filters(kind: kind, providers: selectedProviders, genres: selectedGenres)
                    dismiss()
                }
            }
            // Search
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search movies & shows"
            )
            .onChange(of: searchText) { newValue in
                searchChanged(newValue)
            }
            // Seed working copy
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

    // MARK: - Search (single, debounced, cancellable)
    private func searchChanged(_ newValue: String, immediate: Bool = false) {
        searchTask?.cancel()
        results.removeAll()
        searchError = nil

        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= SearchTuning.minQueryLength else {
            isSearching = false
            lastSearchKey = ""
            return
        }

        // Dedup identical query+kinds to avoid redundant fetches
        let key = "\(normalize(trimmed))#\(kindKey(kind))"
        if key == lastSearchKey, !immediate { return }
        lastSearchKey = key

        searchTask = Task { @MainActor in
            isSearching = true
            do {
                if !immediate { try await Task.sleep(nanoseconds: SearchTuning.debounceNanos) }
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
                // cancelled
            } catch {
                results = []
                searchError = "Couldn’t fetch results."
            }
            isSearching = false
        }
    }

    // MARK: - Helpers
    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) {
            withAnimation(.snappy) { set.remove(value) }
        } else {
            withAnimation(.snappy) { set.insert(value) }
        }
    }

    private func kindKey(_ k: ContentKind) -> String {
        switch k {
        case .all: return "all"
        case .movie: return "movie"
        case .tv: return "tv"
        }
    }

    /// Lowercased, diacritic-insensitive, alnum + spaces only, collapsed spaces.
    private func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var chars = [Character](); chars.reserveCapacity(folded.count)
        var lastWasSpace = false
        for u in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) {
                chars.append(Character(u))
                lastWasSpace = false
            } else if !lastWasSpace {
                chars.append(" ")
                lastWasSpace = true
            }
        }
        if chars.last == " " { chars.removeLast() }
        return String(chars).replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
    }
}

// MARK: - Components

/// A clean card-style container for sections
private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .imageScale(.medium)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(title)
                    .font(.headline.weight(.semibold))
                Spacer()
            }
            .padding(.bottom, 2)

            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 6)
        )
    }
}

/// A tighter, tactile chip with selection affordance
private struct SelectChip: View {
    let title: String
    let isSelected: Bool
    var namespace: Namespace.ID? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.small)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Group {
                    if let ns = namespace, isSelected {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.15))
                            .matchedGeometryEffect(id: "chip-\(title)-bg", in: ns)
                    } else {
                        Capsule()
                            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .animation(.snappy, value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Compact result row for search results
private struct ResultRow: View {
    let item: TitleItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.posterURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "film").imageScale(.large))
                default:
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !item.year.isEmpty {
                    Text(item.year)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A segmented control with a capsule background
private struct SegmentedCapsulePicker<T: Hashable, Label: View>: View {
    @Binding var selection: T
    let cases: [T]
    let label: (T) -> Label

    var body: some View {
        HStack(spacing: 6) {
            ForEach(cases, id: \.self) { value in
                Button {
                    withAnimation(.snappy) { selection = value }
                } label: {
                    HStack(spacing: 6) {
                        label(value)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        ZStack {
                            if selection == value {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.15))
                                    .transition(.opacity.combined(with: .scale))
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selection == value ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

/// Thin summary of active filters with a one-tap clear
private struct ActiveFilterSummary: View {
    let count: Int
    let label: String
    let clearAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            Text("\(count) \(label) selected")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive, action: clearAll) {
                Text("Clear")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

/// Sticky bottom bar with prominent Apply
private struct ApplyBar: View {
    let hasChanges: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Divider().overlay(Color.primary.opacity(0.1))

            HStack(spacing: 12) {
                if !hasChanges {
                    Label("No changes", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    Spacer(minLength: 0)
                }

                Button(action: onApply) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Apply")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(hasChanges ? Color.accentColor : Color.accentColor.opacity(0.5))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!hasChanges)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .padding(.top, 6)
            .background(.regularMaterial)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: -2)
    }
}
