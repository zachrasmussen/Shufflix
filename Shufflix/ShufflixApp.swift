//
//  ShufflixApp.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Updated 10/2 - 8:00
//

import SwiftUI
import Combine

@main
struct ShufflixApp: App {
    // Create VM (and its JSONLibraryStore) once; StateObject preserves it.
    @StateObject private var vm = DeckViewModel(store: JSONLibraryStore())
    @Environment(\.scenePhase) private var scenePhase

    // Prevent duplicate work if the system rapidly flips phases
    @State private var lastHandledPhase: ScenePhase?

    // Use your standalone Supabase sync manager
    private let syncer = SupabaseSyncManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm) // root injection

                // One-time warmup for haptics on first render
                .task {
                    _ = Haptics.shared
                    Haptics.shared.prewarm()
                    Haptics.shared.minInterval = 0.0
                }

                // Initial delta pull on cold start
                .task {
                    await syncer.pullServerDeltas(mergeInto: vm)
                }

                // ScenePhase-driven maintenance with re-entry guards
                .task(id: scenePhase) {
                    guard scenePhase != lastHandledPhase else { return }
                    lastHandledPhase = scenePhase

                    switch scenePhase {
                    case .active:
                        // Quiet top-up on foreground (detached so UI stays snappy)
                        if vm.currentDeck().count < 6 && !vm.isLoading {
                            Task.detached { await vm.loadMore() }
                        }
                        // Pull any server updates since last time
                        await syncer.pullServerDeltas(mergeInto: vm)

                    case .inactive, .background:
                        vm.flush() // flush debounced writes

                    @unknown default:
                        break
                    }
                }

                // Best-effort flush on termination
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
                ) { _ in
                    Task { vm.flush() }
                }
        }
    }
}
