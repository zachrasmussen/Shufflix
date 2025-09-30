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
    supabaseURL: URL(string: "https://qoixoyneimnudkbowmlh.supabase.co")!,
    supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFvaXhveW5laW1udWRrYm93bWxoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTkxNzk3OTAsImV4cCI6MjA3NDc1NTc5MH0.DApIj2oMuiOTaphA6tPvUbI-1yzUA-QfjsV5EMNS8IQ"
  )
}
