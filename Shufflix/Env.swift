//
//  Env.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Refactored: 2025-10-02
//

import Foundation
import os.log

/// Thin façade over `Constants` so the rest of the app can use `Env.*`.
/// All raw config loading lives in `Constants` (Info.plist / env vars / defaults).
enum Env {

  // MARK: - Supabase

  /// Supabase project URL.
  /// - Debug: crashes fast if missing/invalid.
  /// - Release: returns a harmless placeholder (network layer should guard).
  static var supabaseURL: URL {
    let raw = Constants.Supabase.url.removingWrappingQuotes()
    if let url = URL(string: raw), !raw.isEmpty {
      return url
    }
    #if DEBUG
    fatalError("❌ Missing or invalid SUPABASE_URL. Configure per-scheme in Info.plist or ENV.")
    #else
    os_log("⚠️ SUPABASE_URL missing/invalid; using placeholder.", type: .fault)
    return URL(string: "https://invalid.local")!
    #endif
  }

  /// Supabase anon key.
  /// - Debug: crashes fast if empty.
  /// - Release: returns empty string so the app can still launch (calls should handle).
  static var supabaseAnonKey: String {
    let key = Constants.Supabase.anonKey.removingWrappingQuotes()
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

  // MARK: - Optional: runtime config self-checks

  /// Call once at launch (e.g., in `ShufflixApp`) if you want explicit logging in Release too.
  static func validateConfiguration() {
    // Touching these triggers the Debug fatalErrors if misconfigured.
    _ = supabaseURL
    _ = supabaseAnonKey

    // Soft log in all builds
    os_log("Env ✅ appEnv=%{public}@, supabaseURL=%{public}@",
           type: .info, appEnv, supabaseURL.absoluteString)
  }
}

// MARK: - Private helpers

private extension String {
  /// Strips accidental wrapping quotes that can sneak in from plist editing or env exports.
  func removingWrappingQuotes() -> String {
    trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }
}
