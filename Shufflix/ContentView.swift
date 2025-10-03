//
//  ContentView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Refactored: 2025-10-02
//

import SwiftUI
import Supabase

// MARK: - Root Deck View

struct DeckRootView: View {
    @EnvironmentObject private var vm: DeckViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var selected: TitleItem?
    @State private var showFilters = false
    @State private var didPrimeDeck = false   // ensure one-time initial top-up

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let cardWidth  = min(proxy.size.width * 0.9, 420)
                let cardHeight = min(proxy.size.height * 0.78, 680)
                let cardSize   = CGSize(width: cardWidth, height: cardHeight)

                ZStack {
                    Color(UIColor.systemBackground).ignoresSafeArea()

                    // 1) Quiet shell while NOT primed (avoid flicker)
                    if !vm.isPrimed && vm.currentDeck().isEmpty {
                        VStack { Spacer(minLength: 0) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 2) Error state
                    } else if let err = vm.errorMessage, vm.currentDeck().isEmpty {
                        VStack(spacing: 12) {
                            Text("Oops: \(err)")
                                .multilineTextAlignment(.center)
                            Button("Retry") { reloadMore() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding()

                    // 3) Empty (caught up)
                    } else if vm.currentDeck().isEmpty {
                        VStack(spacing: 12) {
                            Text("You’re all caught up")
                                .font(.title2.weight(.semibold))
                            Button("Reload") { reloadMore() }
                                .buttonStyle(.borderedProminent)
                        }

                    // 4) Deck
                    } else {
                        VStack(spacing: 12) {
                            DeckStack(
                                items: vm.currentDeck(),
                                cardSize: cardSize,
                                onTap: { item in selected = item },
                                onAction: { item, like in vm.swipe(item, liked: like) }
                            )
                            .frame(width: cardWidth, height: cardHeight)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .padding(.top, 16)
                            .padding(.horizontal)

                            Spacer(minLength: 0)
                        }
                        .opacity(vm.isPrimed ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: vm.isPrimed)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 44) {
                        Button {
                            if let top = vm.currentDeck().last { vm.swipe(top, liked: false) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.red)
                                .font(.system(size: 75, weight: .bold))
                                .shadow(radius: 6, y: 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skip")
                        .disabled(!vm.isPrimed)

                        Button {
                            if let top = vm.currentDeck().last { vm.swipe(top, liked: true) }
                        } label: {
                            Image(systemName: "heart.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.blue)
                                .font(.system(size: 75, weight: .bold))
                                .shadow(radius: 6, y: 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Like")
                        .disabled(!vm.isPrimed)
                    }
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("Shufflix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Filters (leading)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 22, weight: .medium))
                    }
                    .accessibilityLabel("Filters")
                }
                // Liked (trailing)
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { LikedListView() } label: {
                        Image(systemName: vm.liked.isEmpty ? "heart" : "heart.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(vm.liked.isEmpty ? .primary : .pink)
                    }
                    .accessibilityLabel("Liked")
                }
            }
            .sheet(isPresented: $showFilters) {
                FilterSheet()
                    .presentationDetents([.medium, .large])
            }
            .navigationDestination(item: $selected) { item in
                TitleDetailView(item: item)
            }
            .refreshable { await reloadMoreAsync() }
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

    // MARK: - Async wrappers

    private func primeDeckIfNeeded() {
        if vm.currentDeck().count < 6 {
            Task { await vm.loadMore() }
        }
    }

    private func reloadMore() {
        Task { await vm.loadMore() }
    }

    private func reloadMoreAsync() async {
        await vm.loadMore()
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
                .animation(nil, value: items.count)
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

    private var dragPct: CGFloat {
        let w = max(-1, min(1, offset.width / 200))
        return w
    }
    private var rotation: Angle { .degrees(Double(dragPct) * 8) }
    private var likeOpacity: Double { max(0, Double(dragPct)) }
    private var nopeOpacity: Double { max(0, Double(-dragPct)) }

    @ViewBuilder
    private func stamp(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .heavy, design: .rounded))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundColor(color)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(-12))
            .shadow(color: color.opacity(0.2), radius: 6, y: 3)
    }

    var body: some View {
        ZStack {
            AsyncImage(url: item.posterURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFill()
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

            VStack {
                HStack {
                    stamp("LIKE", color: .green).opacity(likeOpacity)
                    Spacer()
                    stamp("NOPE", color: .red).opacity(nopeOpacity)
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

        .gesture(
            TapGesture()
                .onEnded {
                    guard isTop, !removed, abs(offset.width) < 8, abs(offset.height) < 8 else { return }
                    onTap(item)
                }
        )
        .simultaneousGesture(
            DragGesture()
                .updating($isDragging) { _, state, _ in
                    guard isTop else { return }
                    state = true
                }
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
        )

        .overlay(overlayBadges, alignment: .topLeading)
        .accessibilityLabel(Text("\(item.name), \(item.genres.first ?? "")"))
        .accessibilityHint(Text("Tap for details. Swipe right to like, left to skip."))
    }

    @ViewBuilder
    private var overlayBadges: some View {
        HStack {
            if offset.width > 40 {
                TagBadge(text: "LIKE", tint: .green).transition(.opacity.combined(with: .scale))
            } else if offset.width < -40 {
                TagBadge(text: "SKIP", tint: .red).transition(.opacity.combined(with: .scale))
            }
            Spacer()
        }
        .padding(16)
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
            if isSignedIn {
                DeckRootView()
            } else {
                SignInView()
            }
        }
        .task {
            // Debug prints: confirm which user/env you’re running with
            let uid = Supa.client.auth.currentUser?.id.uuidString ?? "nil"
            print("AUTH uid:", uid)
            print("APP env:", Constants.App.env)

            // Initial session snapshot
            isSignedIn = (Supa.client.auth.currentUser != nil)

            // If already signed in at launch, do a silent liked sync
            if isSignedIn {
                await vm.refreshLikedFromSupabase()
                await vm.hydrateLikedCacheFromSupabase()
            }

            // Stream auth state changes and keep UI + liked list in sync
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
        .onChange(of: scenePhase) { phase in
            // When returning to foreground, refresh liked + cache silently
            if phase == .active, isSignedIn {
                Task {
                    await vm.refreshLikedFromSupabase()
                    await vm.hydrateLikedCacheFromSupabase()
                }
            }
        }
        .onDisappear { authTask?.cancel() }
    }
}
