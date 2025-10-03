//
//  SearchViewModel.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import Combine

@MainActor
final class SearchViewModel: ObservableObject {

  // MARK: - Inputs/Outputs
  @Published var query: String = "" {
    didSet { scheduleDebouncedSearch() }
  }
  @Published private(set) var results: [TitleItem] = []
  @Published private(set) var isLoading: Bool = false
  @Published private(set) var errorMessage: String?

  enum Kind { case all, tv, movie }
  @Published var kind: Kind = .all {
    didSet { scheduleDebouncedSearch() }
  }

  /// Optional: surface in UI if you want a “recent searches” row
  @Published private(set) var recentQueries: [String] = []

  // MARK: - Config
  private let minQueryLength = 1               // more forgiving; 1+ chars allowed
  private let debounceInterval: TimeInterval = 0.25
  private let recentQueriesCap = 10

  // MARK: - State
  private var cancellables = Set<AnyCancellable>()
  private var searchTask: Task<Void, Never>?
  private var debounceWork: DispatchWorkItem?

  /// Avoid re-running identical normalized searches
  private var lastIssuedKey: String = ""

  /// Tiny in-memory cache: normalizedKey → results
  private var cache: [String: [TitleItem]] = [:]
  private var cacheOrder: [String] = []
  private let cacheCap = 24

  // MARK: - Lifecycle
  deinit {
    searchTask?.cancel()
    debounceWork?.cancel()
  }

  // MARK: - Public API

  /// Programmatic submit (e.g., TextField.onSubmit).
  func submit() { performSearch(trigger: .submitted) }

  /// Trigger a search immediately (no debounce).
  func searchImmediately() { performSearch(trigger: .manual) }

  func clear() {
    searchTask?.cancel()
    searchTask = nil
    results = []
    errorMessage = nil
    isLoading = false
    lastIssuedKey = ""
  }

  func clearRecentQueries() {
    recentQueries = []
  }

  // MARK: - Debounce

  private func scheduleDebouncedSearch() {
    debounceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.performSearch(trigger: .queryOrKindChanged)
    }
    debounceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
  }

  // MARK: - Core search

  private enum Trigger { case queryOrKindChanged, submitted, manual }

  private func performSearch(trigger: Trigger) {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard q.count >= minQueryLength else {
      searchTask?.cancel()
      results = []
      errorMessage = nil
      isLoading = false
      lastIssuedKey = ""
      return
    }

    let key = normalizedKey(query: q, kind: kind)
    // Skip redundant search unless user explicitly submitted
    if key == lastIssuedKey && trigger != .submitted { return }
    lastIssuedKey = key

    // Cache hit? Return instantly.
    if let cached = cache[key] {
      results = cached
      errorMessage = nil
      isLoading = false
      touchCacheKey(key)
      noteQuery(q)
      return
    }

    // Cancel any in-flight search and start fresh
    searchTask?.cancel()
    isLoading = true
    errorMessage = nil

    let filter: TMDBService.MediaTypeFilter = {
      switch kind {
      case .all:   return .all
      case .tv:    return .tv
      case .movie: return .movie
      }
    }()

    searchTask = Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        // Pass 1: fast, recall-first (uses SearchRanker internally).
        var hits = try await TMDBService.searchTitles(
          query: q,
          type: filter,
          pageLimit: 3,
          region: Constants.TMDB.defaultRegion
        )

        // If the first pass is thin, try a lenient rescue path:
        // - slightly deeper pages
        // - run our local ranker again (forgives stopwords like “the”)
        if hits.count < 3 {
          let deeper = try? await TMDBService.searchTitles(
            query: q,
            type: filter,
            pageLimit: 4,
            region: Constants.TMDB.defaultRegion
          )
          if let deeper, !deeper.isEmpty { hits = deeper }
        }

        // Final local rank to be extra forgiving (e.g., “the office” → “The Office (US)”)
        let ranked = SearchRanker.rank(query: q, items: hits, limit: 60)

        try Task.checkCancellation()

        self.results = ranked
        self.isLoading = false
        self.errorMessage = nil
        self.noteQuery(q)
        self.putCache(key: key, value: ranked)
      } catch is CancellationError {
        // ignored—newer task took over
      } catch {
        self.results = []
        self.isLoading = false
        self.errorMessage = Self.humanize(error)
        #if DEBUG
        print("[Search] error:", error)
        #endif
      }
    }
  }

  // MARK: - Recent queries

  private func noteQuery(_ q: String) {
    let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Dedup (case-insensitive)
    if recentQueries.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return }
    var arr = recentQueries
    arr.insert(trimmed, at: 0)
    if arr.count > recentQueriesCap { arr.removeLast(arr.count - recentQueriesCap) }
    recentQueries = arr
  }

  // MARK: - Key normalization & cache

  private func normalizedKey(query q: String, kind: Kind) -> String {
    let folded = q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    var scalars = folded.unicodeScalars
    var out = String.UnicodeScalarView()
    out.reserveCapacity(scalars.count)

    var lastWasSpace = false
    for u in scalars {
      if CharacterSet.alphanumerics.contains(u) {
        out.append(u)
        lastWasSpace = false
      } else if !lastWasSpace {
        out.append(" ")
        lastWasSpace = true
      }
    }
    if lastWasSpace, let last = out.popLast(), last == " " { /* trim */ }

    let kindKey: String = {
      switch kind {
      case .all: return "all"
      case .tv: return "tv"
      case .movie: return "movie"
      }
    }()
    return "\(String(out))#\(kindKey)"
  }

  private func putCache(key: String, value: [TitleItem]) {
    cache[key] = value
    cacheOrder.removeAll(where: { $0 == key })
    cacheOrder.insert(key, at: 0)
    if cacheOrder.count > cacheCap, let drop = cacheOrder.popLast() {
      cache.removeValue(forKey: drop)
    }
  }

  private func touchCacheKey(_ key: String) {
    if let idx = cacheOrder.firstIndex(of: key) {
      cacheOrder.remove(at: idx)
      cacheOrder.insert(key, at: 0)
    }
  }

  // MARK: - Error text

  private static func humanize(_ error: Error) -> String {
    // Network-friendly messages
    if let urlErr = error as? URLError {
      switch urlErr.code {
      case .timedOut, .notConnectedToInternet, .networkConnectionLost:
        return "Network seems down. Try again in a moment."
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
        return "Can’t reach the server. Please try again shortly."
      default:
        break
      }
    }

    let ns = error as NSError

    // Our TMDB layer throws NSError(domain: "TMDB", code: ..., userInfo: [NSLocalizedDescriptionKey: "..."])
    if ns.domain == "TMDB" {
      let msg = ns.userInfo[NSLocalizedDescriptionKey] as? String
      return (msg?.isEmpty == false) ? msg! : "TMDB error \(ns.code)"
    }

    // Generic fallback
    return ns.localizedDescription.isEmpty ? "Something went wrong." : ns.localizedDescription
  }
}
