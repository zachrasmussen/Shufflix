//
//  SettingsView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/02/25 - 5:30
//

import SwiftUI
import Supabase

struct SettingsView: View {
    let onClose: () -> Void

    @State private var userEmail: String? = nil
    @State private var isSigningOut = false
    @State private var isDeleting = false   // used for soft delete (deactivation)
    @State private var confirmDelete = false

    // Toast
    @State private var toastMessage: String? = nil
    @State private var toastKind: ToastKind = .success
    @State private var showToast = false

    // Example stats (swap with real values from your VM/store later)
    @State private var watchedCount = 48
    @State private var likedCount   = 132
    @State private var ratedCount   = 77
    @State private var swipedCount  = 891

    @AppStorage("com.shufflix.pref.haptics") private var hapticsOn = true
    @AppStorage("com.shufflix.pref.autoplayWifi") private var autoplayWifi = true

    var body: some View {
        NavigationStack {
            List {
                // MARK: Account
                Section("Account") {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(userEmail ?? "Signed in with Apple")
                                .font(.headline)
                            Text("Manage your profile and data")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: Badges
                Section("Badges & Progress") {
                    BadgesGrid(
                        watched: watchedCount,
                        liked: likedCount,
                        rated: ratedCount,
                        swiped: swipedCount
                    )
                    .padding(.vertical, 4)
                }

                // MARK: Preferences
                Section("Preferences") {
                    Toggle("Haptics", isOn: $hapticsOn)
                    Toggle("Autoplay Trailers (Wi-Fi)", isOn: $autoplayWifi)
                }

                // MARK: About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionString).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(appBuildString).foregroundStyle(.secondary)
                    }
                }

                // MARK: Danger Zone
                Section {
                    Button {
                        Task {
                            isSigningOut = true
                            defer { isSigningOut = false }
                            await signOut()
                            // No onClose(); ContentView flips via authStateChanges
                        }
                    } label: {
                        HStack {
                            Text("Sign Out")
                            if isSigningOut { ProgressView().padding(.leading, 6) }
                        }
                    }
                    .disabled(isDeleting)

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Text("Delete Account")
                    }
                    .disabled(isSigningOut)

                    .confirmationDialog(
                        "Deactivate your account?",
                        isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Deactivate (Soft Delete)", role: .destructive) {
                            Task {
                                isDeleting = true
                                defer { isDeleting = false }
                                await deleteAccount() // soft delete
                                // No onClose(); ContentView flips via authStateChanges
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will deactivate your account (soft delete): your data becomes inaccessible and you’ll be signed out. You can contact support to restore it or request permanent erasure.")
                    }
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Deactivation hides your profile and synced data from the app. For permanent erasure, contact support.")
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose)
                        .disabled(isSigningOut || isDeleting)
                }
            }
            .task {
                if let user = Supa.client.auth.currentUser {
                    userEmail = user.email
                }
            }
            // Overlays: progress blocker + toast banner
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

    // MARK: - Supabase hooks
    private func signOut() async {
        do {
            try await Supa.client.auth.signOut()
            print("✅ Signed out")
            showToast("Signed out", kind: .success)
        } catch {
            print("❌ Sign out failed:", error.localizedDescription)
            showToast("Sign out failed: \(error.localizedDescription)", kind: .error)
        }
    }

    private func deleteAccount() async {
        do {
            // 1) Soft delete on server
            _ = try await Supa.client.database
                .rpc("soft_delete_current_user")
                .execute()
            print("✅ Account soft-deleted (server)")

            // 2) Clear local session so UI flips immediately
            try? await Supa.client.auth.signOut()
            print("✅ Local session cleared")
            showToast("Account deactivated", kind: .success)
        } catch {
            print("❌ Deactivate (soft delete) failed:", error.localizedDescription)
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

// MARK: - Badges

private struct BadgesGrid: View {
    let watched: Int
    let liked: Int
    let rated: Int
    let swiped: Int

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 12) {
            BadgeCard(
                title: "Watcher",
                value: watched,
                systemImage: "tv",
                caption: milestoneLabel(watched, steps: [10, 25, 50, 100])
            )
            BadgeCard(
                title: "Curator",
                value: liked,
                systemImage: "heart.fill",
                caption: milestoneLabel(liked, steps: [25, 50, 100, 250])
            )
            BadgeCard(
                title: "Critic",
                value: rated,
                systemImage: "star.fill",
                caption: milestoneLabel(rated, steps: [10, 50, 100, 200])
            )
            BadgeCard(
                title: "Swiper",
                value: swiped,
                systemImage: "hand.tap.fill",
                caption: milestoneLabel(swiped, steps: [100, 500, 1000, 2500])
            )
        }
    }

    private func milestoneLabel(_ v: Int, steps: [Int]) -> String {
        if let next = steps.first(where: { v < $0 }) {
            return "\(v) • next at \(next)"
        } else {
            return "\(v) • maxed!"
        }
    }
}

private struct BadgeCard: View {
    let title: String
    let value: Int
    let systemImage: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                Spacer()
                Image(systemName: "rosette")
            }
            Text("\(value)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}
