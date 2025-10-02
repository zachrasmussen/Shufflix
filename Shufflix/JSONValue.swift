//
//  JSONValue.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/1/25.
//  Refactored: 2025-10-02 (ergonomic literals)
//

import Foundation

/// Minimal JSON value wrapper for RPC params or dynamic request payloads.
/// Top-level (not actor isolated) so it can be used freely with async code.
@frozen
enum JSONValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case null

    // MARK: - Encodable
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

// MARK: - Literal ergonomics

extension JSONValue: ExpressibleByStringLiteral,
                     ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral,
                     ExpressibleByNilLiteral {

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int)   { self = .int(value) }
    init(floatLiteral value: Double)  { self = .double(value) }
    init(booleanLiteral value: Bool)  { self = .bool(value) }
    init(nilLiteral: ())              { self = .null }
}

// MARK: - Convenience init

extension JSONValue {
    /// Generic convenience init for common scalar types.
    init<T: LosslessStringConvertible>(_ value: T) {
        switch value {
        case let v as Int:    self = .int(v)
        case let v as Int64:  self = .int64(v)
        case let v as Double: self = .double(v)
        case let v as Bool:   self = .bool(v)
        default:              self = .string(value.description)
        }
    }
}
