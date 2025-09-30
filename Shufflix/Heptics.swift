//
//  Heptics.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//Updated 9/27 - 7:45

import UIKit
import CoreHaptics

@MainActor
final class Haptics {
    static let shared = Haptics()

    // MARK: - Config
    /// Toggle all haptics globally (e.g., user setting).
    var isEnabled: Bool = true

    /// Minimal interval between repeated triggers for the same “channel”.
    /// Set to >0 (e.g., 0.08) to lightly throttle spammy gestures.
    var minInterval: TimeInterval = 0

    // MARK: - Internals
    private let supportsHaptics: Bool
    private var lastFire: [Channel: TimeInterval] = [:]

    private enum Channel: Hashable {
        case light, medium, heavy, success, warning, error, selection, soft, rigid
    }

    // Generators (reused)
    private let impactLight  = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy  = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    private let selection    = UISelectionFeedbackGenerator()

    private init() {
        // Simulator reports false; devices with no Taptic Engine also false.
        if #available(iOS 13.0, *) {
            supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        } else {
            supportsHaptics = true // older devices either no-op or still provide basic feedback
        }
        // Pre-warm a little so the first interaction feels instant.
        prepareAll()
    }

    // MARK: - Public (call sites unchanged)

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

    // iOS 13+: extra flavors some teams like to use
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

    /// Call once early (e.g., in App init/`onAppear`) to reduce first-tap latency.
    func prewarm() { prepareAll() }

    // MARK: - Private

    private func prepareAll() {
        guard supportsHaptics, isEnabled else { return }
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notification.prepare()
        selection.prepare()
    }

    private func fire(_ channel: Channel, action: () -> Void) {
        guard isEnabled, supportsHaptics else { return }

        // Optional micro-throttle to avoid engine spam (useful during drag thresholds).
        if minInterval > 0 {
            let now = CACurrentMediaTime()
            if let last = lastFire[channel], now - last < minInterval { return }
            lastFire[channel] = now
        }

        // Generators work best when prepared shortly before use.
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
