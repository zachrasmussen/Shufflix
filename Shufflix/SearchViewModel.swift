//
//  SearchViewModel.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//Updated 9/27 - 7:45

import Foundation
import Combine

@MainActor
final class SearchViewModel: ObservableObject {

    // MARK: - Inputs/Outputs
    @Published var query: String = ""
    @Published private(set) var results: [TitleItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    enum Kind { case all, tv, movie }
    @Published var kind: Kind = .all

    // Optional: surface in UI if you want a “recent searches” row
    @Published private(set) var recentQueries: [String] = []

    // MARK: - Config
    private let minQueryLength = 2
    private let debounceMs: Int = 350

    // State
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var lastIssuedKey: String = "" // avoids re-running identical searches

    // MARK: - Lifecycle
    init() {
        // Debounce only when the query text changes
        $query
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .debounce(for: .milliseconds(debounceMs), scheduler: RunLoop.main)
            .sink { [weak self] q in
                self?.performSearch(triggeredBy: .queryChanged, providedQuery: q)
            }
            .store(in: &cancellables)

        // Re-run immediately when kind changes using the latest query
        $kind
            .sink { [weak self] _ in
                guard let self else { return }
                let q = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
                self.performSearch(triggeredBy: .kindChanged, providedQuery: q)
            }
            .store(in: &cancellables)
    }

    // MARK: - API

    /// Programmatic submit (e.g., from TextField.onSubmit).
    func submit() {
        performSearch(triggeredBy: .submitted,
                      providedQuery: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Triggers a search using current `query` and `kind`.
    /// Safe to call from onSubmit and programmatically.
    func performSearch() {
        performSearch(triggeredBy: .manual,
                      providedQuery: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func clear() {
        searchTask?.cancel()
        searchTask = nil
        results = []
        errorMessage = nil
        isLoading = false
        lastIssuedKey = ""
    }

    // MARK: - Internals

    private enum TriggerReason { case queryChanged, kindChanged, submitted, manual }

    private func performSearch(triggeredBy reason: TriggerReason, providedQuery q: String) {
        // Guard input
        guard q.count >= minQueryLength else {
            searchTask?.cancel()
            results = []
            errorMessage = nil
            isLoading = false
            lastIssuedKey = ""
            return
        }

        // Build a dedup key (query + kind)
        let key = "\(normalize(q))#\(kindKey(kind))"
        guard key != lastIssuedKey || reason == .submitted else {
            // Same query/kind as last time → skip redundant fetch (unless user explicitly submitted)
            return
        }
        lastIssuedKey = key

        // Cancel any in-flight search
        searchTask?.cancel()
        isLoading = true
        errorMessage = nil

        let type: TMDBService.MediaTypeFilter = {
            switch kind {
            case .all:   return .all
            case .tv:    return .tv
            case .movie: return .movie
            }
        }()

        // Launch
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await TMDBService.searchTitles(
                    query: q,
                    type: type,
                    pageLimit: 2,
                    region: Constants.TMDB.defaultRegion
                )
                try Task.checkCancellation()
                await MainActor.run {
                    self.results = hits
                    self.isLoading = false
                    self.noteQuery(q)
                }
            } catch is CancellationError {
                // A newer query took over—ignore.
            } catch {
                await MainActor.run {
                    self.results = []
                    self.isLoading = false
                    self.errorMessage = Self.humanize(error)
                }
                #if DEBUG
                print("Search error:", error)
                #endif
            }
        }
    }

    private func noteQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedup (case-insensitive) + keep last 10
        var arr = recentQueries.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        arr.insert(trimmed, at: 0)
        if arr.count > 10 { arr.removeLast(arr.count - 10) }
        recentQueries = arr
    }

    // MARK: - Helpers

    private func kindKey(_ k: Kind) -> String {
        switch k {
        case .all: return "all"
        case .tv: return "tv"
        case .movie: return "movie"
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
        // collapse 2+ spaces
        return String(chars).replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
    }

    private static func humanize(_ error: Error) -> String {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut, .notConnectedToInternet, .networkConnectionLost:
                return "Network seems down. Try again in a moment."
            default: break
            }
        }
        let ns = error as NSError
        return ns.localizedDescription.isEmpty ? "Something went wrong." : ns.localizedDescription
    }
}
