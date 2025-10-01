//
//  SupabaseClient.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//

import Foundation
import Supabase

enum Supa {
  static let client = SupabaseClient(
    supabaseURL: Env.supabaseURL,
    supabaseKey: Env.supabaseAnonKey
  )
}
