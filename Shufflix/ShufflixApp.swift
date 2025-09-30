//
//  ShufflixApp.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//Updated 9/27 - 7:45

import SwiftUI
import Combine

@main
struct ShufflixApp: App {
    // Create VM (and its JSONLibraryStore) once; StateObject preserves it.
    @StateObject private var vm = DeckViewModel(store: JSONLibraryStore())
    @Environment(\.scenePhase) private var scenePhase

    // Prevent duplicate work if the system rapidly flips phases
    @State private var lastHandledPhase: ScenePhase?
    @State private var cancellables = Set<AnyCancellable>()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm) // root injection

                // One-time warmup for haptics on first render
                .task {
                    _ = Haptics.shared
                    Haptics.shared.prewarm()
                    // Optional: nudge down spam during drags; set to 0 if you prefer current feel.
                    Haptics.shared.minInterval = 0.0
                }

                // ScenePhase-driven maintenance with re-entry guards
                .task(id: scenePhase) {
                    // Guard repeated callbacks for the same phase
                    guard scenePhase != lastHandledPhase else { return }
                    lastHandledPhase = scenePhase

                    switch scenePhase {
                    case .active:
                        // Quiet top-up on foreground (only if we’re visibly running low and not already loading)
                        if vm.currentDeck().count < 6 && !vm.isLoading {
                            await vm.loadMore()
                        }
                    case .inactive, .background:
                        vm.flush() // flush debounced writes
                    @unknown default:
                        break
                    }
                }

                // Best-effort: flush on termination, in case we skip background (rare on iOS but free on macOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    vm.flush()
                }
        }
    }
}
