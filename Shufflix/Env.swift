//
//  Env.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import os

/// Thin façade over `Constants` so the rest of the app can use `Env.*`.
/// All raw config loading lives in `Constants` (Info.plist / env vars / defaults).
@frozen
enum Env {

  // MARK: - Logging

  @inline(__always)
  private static var log: Logger? {
    #if DEBUG
    if #available(iOS 14.0, *) {
      return Logger(subsystem: Bundle.main.bundleIdentifier ?? "Shufflix", category: "Env")
    }
    #endif
    return nil
  }

  // MARK: - Supabase

  /// Supabase project URL.
  /// - Debug: crashes fast if missing/invalid.
  /// - Release: returns a harmless placeholder (network layer should guard).
  static var supabaseURL: URL {
    // De-quote and trim once
    let raw = Constants.Supabase.url.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

    if !raw.isEmpty, let url = URL(string: raw) {
      return url
    }

    #if DEBUG
    fatalError("❌ Missing or invalid SUPABASE_URL. Configure per-scheme in Info.plist or ENV.")
    #else
    log?.fault("SUPABASE_URL missing/invalid; using placeholder.")
    // Intentionally non-routable host
    return URL(string: "https://invalid.local")!
    #endif
  }

  /// Supabase anon key.
  /// - Debug: crashes fast if empty.
  /// - Release: returns empty string so the app can still launch (callers must handle).
  static var supabaseAnonKey: String {
    let key = Constants.Supabase.anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    #if DEBUG
    guard !key.isEmpty else {
      fatalError("❌ Missing SUPABASE_ANON_KEY. Configure per-scheme in Info.plist or ENV.")
    }
    #endif
    return key
  }

  // MARK: - App Environment

  /// Logical environment string (e.g., "prod" | "staging").
  static var appEnv: String { Constants.App.env }

  /// True if running against staging data.
  static var isStaging: Bool { Constants.App.isStaging }

  /// True if running against production data.
  static var isProd: Bool { Constants.App.isProd }

  /// Distribution hints (useful for telemetry/feature flags)
  static var isTestFlight: Bool { Constants.Build.isTestFlight }
  static var isAppStore: Bool { Constants.Build.isAppStore }

  // MARK: - Optional: runtime config self-checks

  /// Call once at launch (e.g., in `ShufflixApp`) to log the effective config in all builds.
  static func validateConfiguration() {
    // Touching these triggers Debug fatalErrors if misconfigured.
    _ = supabaseURL
    _ = supabaseAnonKey

    log?.info("Env ✅ appEnv=\(appEnv, privacy: .public), supabaseURL=\(supabaseURL.absoluteString, privacy: .public), testflight=\(isTestFlight, privacy: .public), appstore=\(isAppStore, privacy: .public)")
  }
}
