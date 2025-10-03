//
//  SupabaseClient.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import Foundation
import Supabase
import PostgREST
import os

enum Supa {
  /// Shared Supabase client (compatible with SDKs that don't support `SupabaseClientOptions`).
  static let client: SupabaseClient = {
    let url = Env.supabaseURL
    let anonKey = Env.supabaseAnonKey

    // --- Minimal, widely-compatible initialization ---
    // Works on older Supabase Swift versions (no options parameter).
    let client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)

    // I can upgrade later to a version that supports `SupabaseClientOptions`,
    // I can switch to the advanced init below for custom headers/session:
    //
    // let cfg = URLSessionConfiguration.default
    // cfg.waitsForConnectivity = true
    // cfg.timeoutIntervalForRequest = 15
    // cfg.timeoutIntervalForResource = 30
    // cfg.requestCachePolicy = .reloadRevalidatingCacheData
    // cfg.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
    //
    // let options = SupabaseClientOptions(
    //   db: .init(schema: "public"),
    //   global: .init(
    //     headers: [
    //       "User-Agent": Self.userAgent,
    //       "X-Client-Info": Self.clientInfo,
    //       "Accept-Language": Constants.TMDB.defaultLanguage,
    //       "X-App-Env": Env.appEnv,
    //       "X-Distribution": Env.isTestFlight ? "testflight" : (Env.isAppStore ? "appstore" : "dev")
    //     ],
    //     session: URLSession(configuration: cfg)
    //   )
    // )
    // let client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey, options: options)

    return client
  }()

  // Convenience
  static var auth: AuthClient { client.auth }
  static var db: PostgrestClient { client.database }

  // MARK: - Utilities

  /// Log active Supabase config at startup.
  static func validate() {
    log?.info("Supabase ✅ url=\(Env.supabaseURL.absoluteString, privacy: .public), env=\(Env.appEnv, privacy: .public)")
  }

  /// Async because modern SDK exposes `auth.session` as async.
  static func isAuthenticated() async -> Bool {
    (try? await client.auth.session) != nil
  }

  static func signOut() async {
    do { try await client.auth.signOut() }
    catch { log?.fault("Supabase signOut failed: \(error.localizedDescription, privacy: .public)") }
  }

  // MARK: - Internals

  private static let log: Logger? = {
    #if DEBUG
    if #available(iOS 14.0, *) {
      return Logger(subsystem: Bundle.main.bundleIdentifier ?? "Shufflix", category: "Supabase")
    }
    #endif
    return nil
  }()

  private static let userAgent: String = {
    let bundle = Bundle.main
    let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Shufflix"
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    let osVer = ProcessInfo.processInfo.operatingSystemVersion
    let ios = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
    let bid = bundle.bundleIdentifier ?? "unknown.bundle"
    return "\(name)/\(version) (\(bid); iOS \(ios); build \(build))"
  }()

  private static let clientInfo: String = {
    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return "shufflix-ios@\(version) (\(Env.appEnv))"
  }()
}
