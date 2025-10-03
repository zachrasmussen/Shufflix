//
//  ShufflixApp.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production Refactor: 2025-10-03
//

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

@main
struct ShufflixApp: App {
    // Single source of truth for app state.
    @StateObject private var vm = DeckViewModel(store: JSONLibraryStore())

    @Environment(\.scenePhase) private var scenePhase
    @State private var lastHandledPhase: ScenePhase?

    // Supabase background sync (pull deltas / apply to VM)
    private let syncer = SupabaseSyncManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)

                // One-time warmup for haptics
                .task(priority: .utility) {
                    _ = Haptics.shared
                    Haptics.shared.prewarm()
                    Haptics.shared.minInterval = 0.0
                }

                // Initial server pull on cold start (don’t block UI)
                .task(priority: .background) {
                    await syncer.pullServerDeltas(mergeInto: vm)
                }

                // Phase-aware maintenance with re-entry guard
                .task(id: scenePhase) {
                    guard scenePhase != lastHandledPhase else { return }
                    lastHandledPhase = scenePhase

                    switch scenePhase {
                    case .active:
                        // Top up the deck if running low (respects MainActor on the VM)
                        if vm.currentDeck().count < 6 && !vm.isLoading {
                            await vm.loadMore()
                        }
                        // Pick up any server changes since last foreground
                        await syncer.pullServerDeltas(mergeInto: vm)

                    case .inactive, .background:
                        // Flush any debounced persistence to disk
                        vm.flush()

                    @unknown default:
                        break
                    }
                }

                // Best-effort flush on app termination (iOS only)
                #if canImport(UIKit)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    vm.flush()
                }
                #endif
        }
    }
}
