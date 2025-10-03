//
//  SettingsView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/02/25
//  Production Refactor: 2025-10-03
//

import SwiftUI
import Supabase

struct SettingsView: View {
    let onClose: () -> Void

    // Toast
    @State private var toastMessage: String? = nil
    @State private var toastKind: ToastKind = .success
    @State private var showToast = false

    // Async states
    @State private var isSigningOut = false
    @State private var isDeleting = false
    @State private var confirmDelete = false
    @State private var isRefreshingStats = false

    // LIKED-focused stats (match LikedListView)
    @State private var likedCount     = 0
    @State private var watchedCount   = 0
    @State private var unwatchedCount = 0
    @State private var ratedCount     = 0

    // Preferences
    @AppStorage("com.shufflix.pref.autoplayWifi") private var autoplayWifi = true

    @EnvironmentObject private var vm: DeckViewModel

    var body: some View {
        NavigationStack {
            List {
                // MARK: Your Stats
                Section("Your Stats") {
                    StatsRow(label: "Liked",     value: likedCount,     systemImage: "heart.fill")
                    StatsRow(label: "Watched",   value: watchedCount,   systemImage: "tv")
                    StatsRow(label: "Unwatched", value: unwatchedCount, systemImage: "eye.slash")
                    StatsRow(label: "Rated",     value: ratedCount,     systemImage: "star.fill")

                    Button {
                        Task { await refreshStats() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh Stats")
                            if isRefreshingStats { Spacer(); ProgressView().padding(.trailing, 2) }
                        }
                    }
                    .disabled(isRefreshingStats || isSigningOut || isDeleting)
                }

                // MARK: Preferences
                Section("Preferences") {
                    Toggle("Autoplay Trailers (Wi-Fi)", isOn: $autoplayWifi)
                }

                // MARK: About
                Section("About") {
                    KeyValueRow(key: "Version", value: appVersionString)
                    KeyValueRow(key: "Build",   value: appBuildString)
                    // If you set APP_ENV in Info.plist, uncomment:
                    // if let env = appEnvString { KeyValueRow(key: "Environment", value: env) }
                }

                // MARK: Danger Zone
                Section {
                    Button {
                        Task {
                            isSigningOut = true
                            defer { isSigningOut = false }
                            await signOut()
                        }
                    } label: {
                        HStack {
                            Text("Sign Out")
                            if isSigningOut { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isDeleting)

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Text("Deactivate Account")
                    }
                    .disabled(isSigningOut)
                    .confirmationDialog(
                        "Deactivate your account?",
                        isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Deactivate", role: .destructive) {
                            Task {
                                isDeleting = true
                                defer { isDeleting = false }
                                await deleteAccount()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will deactivate your account and sign you out. Contact support to restore or request permanent erasure.")
                    }
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Deactivation hides your profile and synced data from the app. For permanent erasure, contact support.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose)
                        .disabled(isSigningOut || isDeleting)
                }
            }

            // Initial stats load
            .task { await refreshStats() }

            // Live updates without Equatable conformance:
            .onReceive(vm.$liked)      { _ in Task { await refreshStats() } }
            .onReceive(vm.$ratings)    { _ in Task { await refreshStats() } }
            .onReceive(vm.$watchedIDs) { _ in Task { await refreshStats() } }

            .overlay {
                ZStack {
                    if isSigningOut || isDeleting {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView()
                            .controlSize(.large)
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    VStack {
                        if showToast, let text = toastMessage {
                            ToastBanner(text: text, kind: toastKind)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .padding(.top, 8)
                        }
                        Spacer()
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .animation(.easeInOut(duration: 0.22), value: showToast)
            }
        }
    }

    // MARK: - Stats refresh (LIKED-focused)
    @MainActor
    private func refreshStats() async {
        isRefreshingStats = true
        defer { isRefreshingStats = false }

        // Source-of-truth: vm.liked / vm.isWatched(_:) / vm.ratings
        let likedIDs   = Set(vm.liked.map(\.id))
        let likedCnt   = likedIDs.count
        let watchedCnt = vm.liked.reduce(0) { $0 + (vm.isWatched($1) ? 1 : 0) }
        let ratedCnt   = vm.ratings.keys.reduce(0) { $0 + (likedIDs.contains($1) ? 1 : 0) }
        let unwatched  = max(likedCnt - watchedCnt, 0)

        withAnimation(.easeOut(duration: 0.15)) {
            likedCount     = likedCnt
            watchedCount   = watchedCnt
            ratedCount     = ratedCnt
            unwatchedCount = unwatched
        }
    }

    // MARK: - Supabase hooks
    private func signOut() async {
        do {
            try await Supa.client.auth.signOut()
            showToast("Signed out", kind: .success)
        } catch {
            showToast("Sign out failed: \(error.localizedDescription)", kind: .error)
        }
    }

    private func deleteAccount() async {
        do {
            _ = try await Supa.client.database
                .rpc("soft_delete_current_user")
                .execute()
            try? await Supa.client.auth.signOut()
            showToast("Account deactivated", kind: .success)
        } catch {
            showToast("Deactivate failed: \(error.localizedDescription)", kind: .error)
        }
    }

    // MARK: - Toast helper
    private func showToast(_ message: String, kind: ToastKind, duration: TimeInterval = 1.6) {
        toastMessage = message
        toastKind = kind
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation { showToast = false }
        }
    }

    // MARK: - Bundle info
    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var appBuildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    private var appEnvString: String? {
        (Bundle.main.infoDictionary?["APP_ENV"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Small UI bits

private struct StatsRow: View {
    let label: String
    let value: Int
    let systemImage: String

    var body: some View {
        HStack {
            Label(label, systemImage: systemImage)
            Spacer()
            Text("\(value)")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack {
            Text(key)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Toast UI

private enum ToastKind { case success, error }

private struct ToastBanner: View {
    let text: String
    let kind: ToastKind

    private var iconName: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }
    private var tint: Color {
        switch kind {
        case .success: return .green
        case .error:   return .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .shadow(radius: 2, y: 1)
    }
}
