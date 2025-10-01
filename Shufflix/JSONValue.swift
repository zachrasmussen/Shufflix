//
//  JSONValue.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/1/25.
//

import Foundation

/// Minimal JSON value wrapper for RPC params.
/// Keep this file top-level (NOT inside any @MainActor type).
enum JSONValue: Encodable, Sendable {
  case string(String)
  case int(Int)
  case int64(Int64)
  case double(Double)
  case bool(Bool)
  case null

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .int(let v):    try c.encode(v)
    case .int64(let v):  try c.encode(v)
    case .double(let v): try c.encode(v)
    case .bool(let v):   try c.encode(v)
    case .null:          try c.encodeNil()
    }
  }
}
