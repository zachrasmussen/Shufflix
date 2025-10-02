//
//  Haptics.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Refactored: 2025-10-02
//

import UIKit
import CoreHaptics

/// Centralized, lightweight haptics manager.
/// - `@MainActor` so UIKit generators are always touched on the main thread.
/// - Reuses generators to minimize allocation/latency.
/// - Optional per-channel throttling to avoid spam during rapid gestures.
@MainActor
final class Haptics {

    // MARK: Singleton
    static let shared = Haptics()

    // MARK: Config
    /// Toggle all haptics globally (e.g., user setting).
    var isEnabled: Bool = true

    /// Minimal interval between repeated triggers for the same channel.
    /// Example: `0.08` to throttle during drags.
    var minInterval: TimeInterval = 0

    // MARK: Internals

    /// Hardware capability; false on simulators and devices without Taptic Engine.
    private let supportsHaptics: Bool

    private enum Channel: Hashable {
        case light, medium, heavy, success, warning, error, selection, soft, rigid
    }

    /// Last-fire timestamp per channel (for throttling).
    private var lastFire: [Channel: TimeInterval] = [:]

    // Reused generators
    private let impactLight  = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy  = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    private let selection    = UISelectionFeedbackGenerator()

    private init() {
        #if targetEnvironment(simulator)
        // Simulators don’t have haptics hardware; keep it false so we skip work.
        self.supportsHaptics = false
        #else
        if #available(iOS 13.0, *) {
            self.supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        } else {
            // Pre-iOS 13: older devices either no-op or very limited vibration feedback.
            // Treat as unsupported to avoid unnecessary work.
            self.supportsHaptics = false
        }
        #endif

        prepareAll()
    }

    // MARK: Public API (unchanged call sites)

    // Impact
    func light()  { fire(.light)  { impactLight.impactOccurred() } }
    func impact() { fire(.medium) { impactMedium.impactOccurred() } }
    func heavy()  { fire(.heavy)  { impactHeavy.impactOccurred() } }

    // Notification
    func success() { fire(.success) { notification.notificationOccurred(.success) } }
    func warning() { fire(.warning) { notification.notificationOccurred(.warning) } }
    func error()   { fire(.error)   { notification.notificationOccurred(.error) } }

    // Selection
    func selectionChanged() { fire(.selection) { selection.selectionChanged() } }

    // iOS 13+: additional impact styles
    func soft() {
        if #available(iOS 13.0, *) {
            let g = UIImpactFeedbackGenerator(style: .soft)
            g.prepare(); fire(.soft) { g.impactOccurred() }
        } else {
            light()
        }
    }

    func rigid() {
        if #available(iOS 13.0, *) {
            let g = UIImpactFeedbackGenerator(style: .rigid)
            g.prepare(); fire(.rigid) { g.impactOccurred() }
        } else {
            heavy()
        }
    }

    /// Call once early (e.g., in App init / first scene onAppear) to reduce first-tap latency.
    func prewarm() { prepareAll() }

    // Extra: a single entrypoint if you ever want to map UI events to styles
    enum Ping {
        case light, medium, heavy, success, warning, error, selection, soft, rigid
    }
    func ping(_ kind: Ping) {
        switch kind {
        case .light: light()
        case .medium: impact()
        case .heavy: heavy()
        case .success: success()
        case .warning: warning()
        case .error: error()
        case .selection: selectionChanged()
        case .soft: soft()
        case .rigid: rigid()
        }
    }

    // MARK: Private

    private func prepareAll() {
        guard isEnabled, supportsHaptics else { return }
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notification.prepare()
        selection.prepare()
    }

    private func fire(_ channel: Channel, action: () -> Void) {
        guard isEnabled, supportsHaptics else { return }

        // Optional micro-throttle to avoid spamming the engine.
        if minInterval > 0 {
            let now = CACurrentMediaTime()
            if let last = lastFire[channel], now - last < minInterval { return }
            lastFire[channel] = now
        }

        // Generators feel snappiest when prepared just before use.
        switch channel {
        case .light:    impactLight.prepare()
        case .medium:   impactMedium.prepare()
        case .heavy:    impactHeavy.prepare()
        case .success, .warning, .error: notification.prepare()
        case .selection: selection.prepare()
        case .soft, .rigid: break // prepared per-call above
        }

        action()
    }
}
