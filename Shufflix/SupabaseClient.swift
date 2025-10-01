//
//  SupabaseClient.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//

import Foundation
import Supabase
import PostgREST // optional, but handy if you want AnyJSON or explicit db type access

enum Supa {
  /// Shared Supabase client used across the app.
  static let client: SupabaseClient = {
    // Pull URL/key from Constants.Supabase (per-scheme via Info.plist)
    let urlString = Constants.Supabase.url
    let anonKey   = Constants.Supabase.anonKey

    guard let url = URL(string: urlString), !anonKey.isEmpty else {
      #if DEBUG
      fatalError("❌ Supabase not configured. Check SUPABASE_URL / SUPABASE_ANON_KEY in Info.plist for this scheme.")
      #else
      // In release, fail loudly as well; we can't create a valid client without config.
      fatalError("Supabase not configured.")
      #endif
    }

    return SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
  }()

  // Convenience accessors (optional)
  static var auth: AuthClient { client.auth }
  static var db: PostgrestClient { client.database }
}
