//
//  Haptics.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import UIKit
import CoreHaptics

/// Centralized, lightweight haptics manager.
/// - Always main-thread safe (`@MainActor`).
/// - Reuses generators to minimize allocation/latency.
/// - Per-channel throttling prevents spam during rapid gestures.
/// - Provides consistent entrypoints for UI feedback.
@MainActor
final class Haptics {

  // MARK: - Singleton
  static let shared = Haptics()

  // MARK: - Config
  /// Toggle all haptics globally (e.g. user setting).
  var isEnabled: Bool = true

  /// Minimal interval between repeated triggers for the same channel.
  /// Example: `0.08` to throttle during drags.
  var minInterval: TimeInterval = 0

  // MARK: - Internals

  /// Hardware capability; false on simulators or devices without Taptic Engine.
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

  // Cache soft/rigid for iOS 13+
  private lazy var impactSoft: UIImpactFeedbackGenerator? = {
    if #available(iOS 13.0, *) { return UIImpactFeedbackGenerator(style: .soft) }
    return nil
  }()
  private lazy var impactRigid: UIImpactFeedbackGenerator? = {
    if #available(iOS 13.0, *) { return UIImpactFeedbackGenerator(style: .rigid) }
    return nil
  }()

  private init() {
    #if targetEnvironment(simulator)
    self.supportsHaptics = false
    #else
    if #available(iOS 13.0, *) {
      self.supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    } else {
      self.supportsHaptics = false
    }
    #endif

    prepareAll()
  }

  // MARK: - Public API (unchanged call sites)

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
    if let g = impactSoft {
      g.prepare(); fire(.soft) { g.impactOccurred() }
    } else {
      light()
    }
  }

  func rigid() {
    if let g = impactRigid {
      g.prepare(); fire(.rigid) { g.impactOccurred() }
    } else {
      heavy()
    }
  }

  /// Call once early (e.g., in App init / first scene onAppear) to reduce first-tap latency.
  func prewarm() { prepareAll() }

  /// Unified entrypoint for dynamic mapping.
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

  // MARK: - Private

  private func prepareAll() {
    guard isEnabled, supportsHaptics else { return }
    impactLight.prepare()
    impactMedium.prepare()
    impactHeavy.prepare()
    notification.prepare()
    selection.prepare()
    impactSoft?.prepare()
    impactRigid?.prepare()
  }

  private func fire(_ channel: Channel, action: () -> Void) {
    guard isEnabled, supportsHaptics else { return }

    // Optional per-channel throttle
    if minInterval > 0 {
      let now = CACurrentMediaTime()
      if let last = lastFire[channel], now - last < minInterval { return }
      lastFire[channel] = now
    }

    // Pre-prepare generators for max responsiveness
    switch channel {
    case .light:    impactLight.prepare()
    case .medium:   impactMedium.prepare()
    case .heavy:    impactHeavy.prepare()
    case .success, .warning, .error: notification.prepare()
    case .selection: selection.prepare()
    case .soft: impactSoft?.prepare()
    case .rigid: impactRigid?.prepare()
    }

    action()
  }
}
