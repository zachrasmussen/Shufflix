//
//  Env.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//

import Foundation

enum Env {
  static var supabaseURL: URL {
    guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String else {
      fatalError("Missing SUPABASE_URL in Info.plist")
    }
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
               .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    guard let url = URL(string: s) else {
      fatalError("Invalid SUPABASE_URL after trimming: \(s)")
    }
    return url
  }

  static var supabaseAnonKey: String {
    guard let s = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String else {
      fatalError("Missing SUPABASE_ANON_KEY")
    }
    return s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  static var isStaging: Bool {
    #if STAGING
    return true
    #else
    return false
    #endif
  }
}
