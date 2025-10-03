//
//  ContentView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production Refactor: 2025-10-03
//

import SwiftUI
import Supabase

// MARK: - Root Deck View

struct DeckRootView: View {
    @EnvironmentObject private var vm: DeckViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var selected: TitleItem?
    @State private var showFilters = false
    @State private var showSettings = false
    @State private var didPrimeDeck = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let cardWidth  = min(proxy.size.width * 0.9, 420)
                let cardHeight = min(proxy.size.height * 0.78, 680)
                let cardSize   = CGSize(width: cardWidth, height: cardHeight)

                ZStack {
                    Color(UIColor.systemBackground).ignoresSafeArea()

                    if !vm.isPrimed && vm.currentDeck().isEmpty {
                        // Quiet shell before first prime to avoid flicker
                        Color.clear
                    } else if let err = vm.errorMessage, vm.currentDeck().isEmpty {
                        ErrorStateView(message: err, onRetry: { reloadMore() })
                            .padding()
                    } else if vm.currentDeck().isEmpty {
                        EmptyStateView(onReload: { reloadMore() })
                    } else {
                        DeckAreaView(
                            items: vm.currentDeck(),
                            cardSize: cardSize,
                            width: cardWidth,
                            height: cardHeight,
                            isPrimed: vm.isPrimed,
                            onTap: { selected = $0 },
                            onSwipe: { item, like in vm.swipe(item, liked: like) }
                        )
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    BottomBar(
                        canAct: vm.isPrimed,
                        onSkip: {
                            if let top = vm.currentDeck().last { vm.swipe(top, liked: false) }
                        },
                        onLike: {
                            if let top = vm.currentDeck().last { vm.swipe(top, liked: true) }
                        }
                    )
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("Shufflix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 22, weight: .medium))
                    }
                    .accessibilityLabel("Filters")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { LikedListView() } label: {
                        Image(systemName: vm.liked.isEmpty ? "heart" : "heart.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(vm.liked.isEmpty ? .primary : .pink)
                    }
                    .accessibilityLabel("Liked")
                }
            }
            // Filters Sheet
            .sheet(isPresented: $showFilters) {
                FilterSheet(onOpenSettings: {
                    showFilters = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showSettings = true
                    }
                })
                .environmentObject(vm)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(20)
            }
            // Full-screen Settings
            .fullScreenCover(isPresented: $showSettings) {
                SettingsView(onClose: { showSettings = false })
            }
            .navigationDestination(item: $selected) { item in
                TitleDetailView(item: item)
            }
            .refreshable { await vm.loadMore() }
            .onAppear {
                if !didPrimeDeck {
                    didPrimeDeck = true
                    primeDeckIfNeeded()
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background { vm.flush() }
            }
        }
    }

    // MARK: - Async

    private func primeDeckIfNeeded() {
        guard vm.currentDeck().count < 6 else { return }
        Task { await vm.loadMore() }
    }

    private func reloadMore() {
        Task { await vm.loadMore() }
    }
}

// MARK: - Subviews (struct-based to avoid opaque-return helpers)

private struct ErrorStateView: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("Oops: \(message)")
                .multilineTextAlignment(.center)
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct EmptyStateView: View {
    let onReload: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("You’re all caught up")
                .font(.title2.weight(.semibold))
            Button("Reload", action: onReload)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct DeckAreaView: View {
    let items: [TitleItem]
    let cardSize: CGSize
    let width: CGFloat
    let height: CGFloat
    let isPrimed: Bool
    let onTap: (TitleItem) -> Void
    let onSwipe: (TitleItem, Bool) -> Void

    var body: some View {
        VStack(spacing: 12) {
            DeckStack(
                items: items,
                cardSize: cardSize,
                onTap: onTap,
                onAction: onSwipe
            )
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 16)
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .opacity(isPrimed ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isPrimed)
    }
}

private struct BottomBar: View {
    let canAct: Bool
    let onSkip: () -> Void
    let onLike: () -> Void

    var body: some View {
        HStack(spacing: 44) {
            Button(action: onSkip) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.red)
                    .font(.system(size: 75, weight: .bold))
                    .shadow(radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip")
            .disabled(!canAct)

            Button(action: onLike) {
                Image(systemName: "heart.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.blue)
                    .font(.system(size: 75, weight: .bold))
                    .shadow(radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Like")
            .disabled(!canAct)
        }
    }
}

// MARK: - DeckStack

struct DeckStack: View {
    let items: [TitleItem]
    let cardSize: CGSize
    let onTap: (TitleItem) -> Void
    let onAction: (TitleItem, Bool) -> Void

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isTop = (index == items.count - 1)
                SwipeCard(
                    item: item,
                    cardSize: cardSize,
                    onTap: onTap,
                    onRemove: onAction,
                    isTop: isTop
                )
                .zIndex(Double(index))
            }
        }
    }
}

// MARK: - SwipeCard

struct SwipeCard: View {
    let item: TitleItem
    let cardSize: CGSize
    let onTap: (TitleItem) -> Void
    let onRemove: (TitleItem, Bool) -> Void
    let isTop: Bool

    @State private var offset: CGSize = .zero
    @GestureState private var isDragging = false
    @State private var didCrossThreshold = false
    @State private var removed = false

    private var dragPct: CGFloat { max(-1, min(1, offset.width / 200)) }
    private var rotation: Angle { .degrees(Double(dragPct) * 8) }

    var body: some View {
        ZStack {
            AsyncImage(url: item.posterURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .offset(x: offset.width * 0.07)
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

            // LIKE / NOPE overlays
            VStack {
                HStack {
                    CardStamp(text: "LIKE", color: .green)
                        .opacity(max(0, Double(dragPct)))
                    Spacer()
                    CardStamp(text: "NOPE", color: .red)
                        .opacity(max(0, Double(-dragPct)))
                }
                .padding(12)
                Spacer()
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(isTop ? 0.12 : 0), radius: isTop ? 12 : 0, y: isTop ? 6 : 0)
        .rotationEffect(rotation, anchor: .bottom)
        .offset(offset)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: offset)
        .contentShape(Rectangle())
        .gesture(tapGesture.simultaneously(with: dragGesture))
        .overlay(overlayBadges, alignment: .topLeading)
        .accessibilityLabel("\(item.name), \(item.genres.first ?? "")")
        .accessibilityHint("Tap for details. Swipe right to like, left to skip.")
    }

    // MARK: Gestures
    private var tapGesture: some Gesture {
        TapGesture().onEnded {
            guard isTop, !removed, abs(offset.width) < 8, abs(offset.height) < 8 else { return }
            onTap(item)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($isDragging) { _, state, _ in if isTop { state = true } }
            .onChanged { value in
                guard isTop, !removed else { return }
                offset = value.translation
                let crossed = abs(dragPct) > 0.55
                if crossed != didCrossThreshold {
                    didCrossThreshold = crossed
                    if crossed { Haptics.shared.light() }
                }
            }
            .onEnded { value in
                guard isTop, !removed else { return }
                let vx = value.predictedEndTranslation.width
                let like = dragPct > 0.6 || vx > 500
                let nope = dragPct < -0.6 || vx < -500
                if like || nope {
                    removed = true
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        offset.width = like ? 900 : -900
                        offset.height += 20
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        onRemove(item, like)
                    }
                    Haptics.shared.success()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        offset = .zero
                    }
                    didCrossThreshold = false
                }
            }
    }

    // MARK: Overlay
    @ViewBuilder
    private var overlayBadges: some View {
        HStack {
            if offset.width > 40 {
                TagBadge(text: "LIKE", tint: .green)
            } else if offset.width < -40 {
                TagBadge(text: "SKIP", tint: .red)
            }
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - CardStamp

private struct CardStamp: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .heavy, design: .rounded))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundColor(color)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(-12))
            .shadow(color: color.opacity(0.2), radius: 6, y: 3)
    }
}

// MARK: - TagBadge

struct TagBadge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.headline.weight(.heavy))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(tint, lineWidth: 3))
            .foregroundColor(tint)
            .shadow(radius: 3, y: 2)
    }
}

// MARK: - Root App ContentView

struct ContentView: View {
    @EnvironmentObject private var vm: DeckViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var isSignedIn = false
    @State private var authTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isSignedIn { DeckRootView() }
            else { SignInView() }
        }
        .task { await setupAuthStream() }
        .onChange(of: scenePhase) { phase in
            if phase == .active, isSignedIn {
                Task {
                    await vm.refreshLikedFromSupabase()
                    await vm.hydrateLikedCacheFromSupabase()
                }
            }
        }
        .onDisappear { authTask?.cancel() }
    }

    // MARK: - Auth
    private func setupAuthStream() async {
        let uid = Supa.client.auth.currentUser?.id.uuidString ?? "nil"
        print("AUTH uid:", uid, "ENV:", Constants.App.env)

        isSignedIn = (Supa.client.auth.currentUser != nil)

        if isSignedIn {
            await vm.refreshLikedFromSupabase()
            await vm.hydrateLikedCacheFromSupabase()
        }

        authTask?.cancel()
        authTask = Task {
            for await (event, session) in Supa.client.auth.authStateChanges {
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    isSignedIn = (session != nil)
                    if isSignedIn {
                        await vm.refreshLikedFromSupabase()
                        await vm.hydrateLikedCacheFromSupabase()
                    }
                case .signedOut, .userDeleted:
                    isSignedIn = false
                default:
                    break
                }
            }
        }
    }
}
