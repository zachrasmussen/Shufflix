//
//  TitleDetailView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-04 (trailers temporarily disabled)
//

import SwiftUI

// Local feature flags for this file only (safe to delete when centralizing)
private enum Features {
    static let showTrailers = false   // flip to true when you bring trailers back
}

private enum DetailUI {
    static let posterCorner: CGFloat = 18
    static let glassRadius: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 14
    static let castCardWidth: CGFloat = 140
    static let providerTileSize: CGFloat = 52
    static let maxGenresChips = 3
}

struct TitleDetailView: View {
    @EnvironmentObject var vm: DeckViewModel
    @Environment(\.dismiss) private var dismiss

    let item: TitleItem

    // Remote bits
    @State private var cast: [TMDBService.CastMember] = []
    @State private var providersState: [ProviderLink] = []
    @State private var certification: String?

    // UI bits
    @State private var isLoading = true
    @State private var overviewText: String = ""
    @State private var expandedOverview = false
    @State private var localRating: Int = 0

    // Cancellation
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: DetailUI.sectionSpacing) {

                    // MARK: Poster (trailers off)
                    PosterOnly(
                        url: item.posterURL,
                        certification: certification
                    )

                    // MARK: Stats Row
                    StatsRow(item: item)

                    // MARK: About (collapsible overview + genre chips)
                    if !(overviewText.isEmpty && item.genres.isEmpty) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("About", systemImage: "info.circle")
                                    .font(.headline)

                                if !overviewText.isEmpty {
                                    CollapsibleText(text: overviewText, expanded: $expandedOverview)
                                }

                                if !item.genres.isEmpty {
                                    GenreChipsGrid(genres: Array(item.genres.prefix(DetailUI.maxGenresChips)))
                                        .padding(.top, overviewText.isEmpty ? 0 : 4)
                                }
                            }
                        }
                    }

                    // MARK: Where to watch
                    if !providersState.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Where to watch", systemImage: "play.rectangle.on.rectangle")
                                    .font(.headline)
                                ProviderGrid(links: providersState, item: item)
                            }
                        }
                    }

                    // MARK: Cast
                    Group {
                        if isLoading {
                            ProgressView("Loading details…")
                                .frame(maxWidth: .infinity)
                        } else if !cast.isEmpty {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("Cast", systemImage: "person.3")
                                        .font(.headline)
                                    CastCarousel(cast: Array(cast.prefix(12)))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 100) // leave room for sticky bar
            }

            // MARK: Sticky Action Bar
            ActionBar(
                isLiked: vm.isLiked(item),
                rating: Binding(
                    get: {
                        // Prefer persisted value when available; fall back to local while store catches up
                        vm.rating(for: item) ?? localRating
                    },
                    set: { new in
                        localRating = new
                        vm.setRating(for: item, to: new)
                    }
                ),
                onLike: {
                    if vm.isLiked(item) {
                        vm.toggleLike(item)
                        Haptics.shared.impact()
                    } else {
                        vm.likeFromDetail(item)
                        Haptics.shared.success()
                        // Pop back to the deck after a like for a snappier flow
                        dismiss()
                    }
                }
            )
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 12)
            .shadow(radius: 10, y: 4)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.id) {
            // Cancel any in-flight work tied to the previous item
            loadTask?.cancel()
            loadTask = Task { await loadDetails() }
            await loadTask?.value
        }
        .onDisappear {
            // Stop any in-flight work if the view leaves
            loadTask?.cancel()
        }
        // Keep local rating in sync if something external changes it
        .onReceive(vm.$deck) { _ in
            localRating = vm.rating(for: item) ?? localRating
        }
    }

    // MARK: - Data

    private func loadDetails() async {
        isLoading = true
        overviewText = item.overview
        providersState = dedupProviders(item.providers)
        localRating = vm.rating(for: item) ?? 0

        // Run in parallel; only fetch remote bits we still need.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let fetched = try? await TMDBService.fetchCast(for: item.id, mediaType: item.mediaType),
                   !Task.isCancelled {
                    await MainActor.run { self.cast = fetched }
                }
            }

            group.addTask {
                if self.providersState.isEmpty,
                   let fetched = try? await TMDBService.watchProviders(for: self.item.id, mediaType: self.item.mediaType),
                   !Task.isCancelled {
                    await MainActor.run { self.providersState = dedupProviders(fetched) }
                }
            }

            // TRAILER_TODO: Re-enable this block when Features.showTrailers == true
            if Features.showTrailers {
                group.addTask {
                    _ = () // intentionally noop; placeholder to keep structure
                    // Example when re-enabling:
                    // if let vids = try? await TMDBService.fetchVideos(for: self.item.id, mediaType: self.item.mediaType),
                    //    let best = TMDBService.bestTrailerURL(from: vids),
                    //    !Task.isCancelled {
                    //    await MainActor.run { self.trailerURL = best }
                    // }
                }
            }

            group.addTask {
                if self.certification == nil,
                   let cert = try? await TMDBService.fetchCertification(for: self.item.id, mediaType: self.item.mediaType),
                   !Task.isCancelled {
                    await MainActor.run { self.certification = cert }
                }
            }

            for await _ in group { if Task.isCancelled { return } }
        }

        if !Task.isCancelled {
            isLoading = false
        }
    }
}

// MARK: - Poster Only (trailers disabled)

private struct PosterOnly: View {
    let url: URL?
    let certification: String?

    var body: some View {
        ZStack {
            AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty:
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .overlay(ProgressView().controlSize(.small))
                case .failure:
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "film").imageScale(.large))
                @unknown default:
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .clipped()

            // Certification chip
            if let cert = certification, !cert.isEmpty {
                HStack {
                    Text(cert)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
            }
        }
        .aspectRatio(2/3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DetailUI.posterCorner, style: .continuous))
        .shadow(radius: 8, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Poster")
    }
}

// MARK: - Stats Row

private struct StatsRow: View {
    let item: TitleItem

    var body: some View {
        HStack(spacing: 8) {
            if let avg = item.tmdbRating, let votes = item.tmdbVoteCount, votes > 0 {
                StatPill(
                    icon: "star.fill",
                    text: String(format: "%.1f", avg),
                    sub: "\(votes.abbrev) votes",
                    tint: .yellow
                )
            }
            StatPill(icon: "calendar", text: item.year.isEmpty ? "—" : item.year, sub: "Year")
            if let first = item.genres.first {
                StatPill(icon: "sparkles", text: first, sub: "Genre")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatPill: View {
    let icon: String
    let text: String
    var sub: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .imageScale(.medium)
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(text).font(.subheadline.weight(.semibold))
                if let sub {
                    Text(sub).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text) \(sub ?? "")")
    }
}

// MARK: - Collapsible Text

private struct CollapsibleText: View {
    let text: String
    @Binding var expanded: Bool
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.body)
                .lineLimit(expanded ? nil : 4)
                .background(
                    Text(text)
                        .font(.body)
                        .lineLimit(4)
                        .overlay(
                            GeometryReader { proxy in
                                Color.clear.onAppear {
                                    // ~4 * 18pt tall when untruncated with default body
                                    truncated = proxy.size.height > 72
                                }
                            }
                        )
                        .hidden()
                )
            if truncated {
                Button(expanded ? "Show less" : "Read more") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .contentShape(Rectangle())
            }
        }
    }
}

// MARK: - Genre Chips Grid

private struct GenreChipsGrid: View {
    let genres: [String]
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 88), spacing: 8)] }
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(genres, id: \.self) { g in
                Chip(text: g).accessibilityLabel("Genre \(g)")
            }
        }
    }
}

// MARK: - Provider Grid

private struct ProviderGrid: View {
    let links: [ProviderLink]
    let item: TitleItem

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: DetailUI.providerTileSize), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(links, id: \.self) { link in
                ProviderTile(link: link, item: item)
            }
        }
    }
}

private struct ProviderTile: View {
    let link: ProviderLink
    let item: TitleItem

    var body: some View {
        Button {
            // Deep-link to app if installed; otherwise universal link; otherwise aggregator/Google
            StreamingLinker.open(
                providerName: link.name,
                title: item.name,
                year: Int(item.year) // optional; improves search accuracy if numeric
            )
        } label: {
            VStack(spacing: 8) {
                if let logo = link.logoURL {
                    AsyncImage(url: logo, transaction: .init(animation: .easeInOut(duration: 0.15))) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit()
                        case .empty: Rectangle().fill(Color.secondary.opacity(0.15)).overlay(ProgressView().controlSize(.mini))
                        case .failure: Rectangle().fill(Color.secondary.opacity(0.15)).overlay(Image(systemName: "play.rectangle").imageScale(.medium))
                        @unknown default: Rectangle().fill(Color.secondary.opacity(0.15))
                        }
                    }
                    .frame(width: DetailUI.providerTileSize, height: DetailUI.providerTileSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text(link.name)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                }

                Text(link.name)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(link.name)")
    }
}

// MARK: - Cast Carousel

private struct CastCarousel: View {
    let cast: [TMDBService.CastMember]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(cast, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        Circle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Text(initials(for: c.name))
                                    .font(.headline.weight(.bold))
                                    .foregroundColor(.secondary)
                            )

                        Text(c.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .frame(maxWidth: DetailUI.castCardWidth, alignment: .leading)

                        if let role = c.character, !role.isEmpty {
                            Text(role)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .frame(width: DetailUI.castCardWidth, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(c.name)\(c.character.flatMap({ " as \($0)" }) ?? "")")
                }
            }
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first
        let last  = parts.dropFirst().first?.first
        return String([first, last].compactMap { $0 })
    }
}

// MARK: - Sticky Action Bar

private struct ActionBar: View {
    let isLiked: Bool
    @Binding var rating: Int
    let onLike: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onLike) {
                HStack(spacing: 8) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.title2.weight(.bold))
                    Text(isLiked ? "Liked" : "Like")
                        .font(.headline)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(isLiked ? Color.pink.opacity(0.15) : Color.blue.opacity(0.12), in: Capsule())
                .foregroundColor(isLiked ? .pink : .blue)
            }
            .buttonStyle(.plain)

            Divider().frame(height: 28)

            RatingStars(rating: $rating)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

private struct RatingStars: View {
    @Binding var rating: Int
    private let max = 5

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...max, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .foregroundColor(.yellow)
                    .imageScale(.large)
                    .onTapGesture { rating = i }
                    .accessibilityLabel("Rate \(i) star\(i == 1 ? "" : "s")")
            }
        }
        .accessibilityLabel("Rate")
    }
}

// MARK: - Small UI Building Blocks

private struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(DetailUI.cardPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DetailUI.glassRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DetailUI.glassRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Helpers

private func dedupProviders(_ links: [ProviderLink]) -> [ProviderLink] {
    var seen = Set<String>()
    var out: [ProviderLink] = []
    out.reserveCapacity(links.count)
    for l in links {
        let key = l.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if seen.insert(key).inserted { out.append(l) }
    }
    return out
}

private extension Int {
    var abbrev: String {
        if self >= 1_000_000 { return String(format: "%.1fm", Double(self)/1_000_000).replacingOccurrences(of: ".0", with: "") }
        if self >= 1_000 { return String(format: "%.1fk", Double(self)/1_000).replacingOccurrences(of: ".0", with: "") }
        return "\(self)"
    }
}
