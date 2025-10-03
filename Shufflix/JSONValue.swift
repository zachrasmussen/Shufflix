//
//  JSONValue.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/1/25.
//  Production Refactor: 2025-10-03
//

import Foundation

/// Lightweight, value-type JSON wrapper for RPC params or dynamic payloads.
/// - Supports: string / int / int64 / double / bool / null / array / object
/// - Codable & Sendable, with literal ergonomics and small utilities.
@frozen
enum JSONValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Encodable
    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)

        case .int(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)

        case .int64(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)

        case .double(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)

        case .bool(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)

        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()

        case .array(let arr):
            var c = encoder.unkeyedContainer()
            for el in arr { try c.encode(el) }

        case .object(let dict):
            var c = encoder.container(keyedBy: CodingKeys.self)
            for (k, v) in dict { try c.encode(v, forKey: .init(stringValue: k)!) }
        }
    }

    // MARK: - Decodable
    init(from decoder: Decoder) throws {
        // Try keyed container first (object), then unkeyed (array), then scalar.
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            var obj: [String: JSONValue] = [:]
            for key in keyed.allKeys {
                obj[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(obj)
            return
        }

        if var unkeyed = try? decoder.unkeyedContainer() {
            var arr: [JSONValue] = []
            while !unkeyed.isAtEnd {
                arr.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(arr)
            return
        }

        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i64 = try? c.decode(Int64.self) {
            if i64 >= Int64(Int.min) && i64 <= Int64(Int.max) {
                self = .int(Int(i64))
            } else {
                self = .int64(i64)
            }
            return
        }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }

        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    // MARK: - CodingKeys
    private struct CodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int)       { self.stringValue = "\(intValue)"; self.intValue = intValue }
    }
}

// MARK: - Literal ergonomics

extension JSONValue: ExpressibleByStringLiteral,
                     ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral,
                     ExpressibleByNilLiteral,
                     ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {

    // Scalars
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int)   { self = .int(value) }
    init(floatLiteral value: Double)  { self = .double(value) }
    init(booleanLiteral value: Bool)  { self = .bool(value) }
    init(nilLiteral: ())              { self = .null }

    // Array
    init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }

    // Object
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        var dict: [String: JSONValue] = [:]
        dict.reserveCapacity(elements.count)
        for (k, v) in elements { dict[k] = v }
        self = .object(dict)
    }
}

// MARK: - Convenience initializers

extension JSONValue {
    /// Generic scalar convenience init; falls back to `.string` using `description`.
    init<T: LosslessStringConvertible>(_ value: T) {
        switch value {
        case let v as Int:    self = .int(v)
        case let v as Int64:  self = .int64(v)
        case let v as Double: self = .double(v)
        case let v as Bool:   self = .bool(v)
        case let v as String: self = .string(v)
        default:              self = .string(value.description)
        }
    }

    /// Wraps `[String: Encodable]` by encoding each value independently.
    /// Renamed to avoid ambiguity with the `.object` enum case.
    static func jsonObject<E: Encodable>(_ dict: [String: E]) throws -> JSONValue {
        var out: [String: JSONValue] = [:]
        out.reserveCapacity(dict.count)
        let encoder = JSONEncoder()
        for (k, v) in dict {
            let data = try encoder.encode(AnyEncodable(v))
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            out[k] = decoded
        }
        return .object(out)
    }

    /// Wraps `[Encodable]` into `.array`.
    /// Renamed to avoid ambiguity with the `.array` enum case.
    static func jsonArray<E: Encodable>(_ arr: [E]) throws -> JSONValue {
        let encoder = JSONEncoder()
        let data = try encoder.encode(arr.map(AnyEncodable.init))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Small conveniences

extension JSONValue {
    var isNull: Bool {
        if case .null = self { return true } else { return false }
    }

    /// Read object member.
    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    /// Read array index (safe).
    subscript(index: Int) -> JSONValue? {
        guard case .array(let arr) = self, arr.indices.contains(index) else { return nil }
        return arr[index]
    }

    /// Convert to Data.
    func toJSONData(pretty: Bool = false) throws -> Data {
        let enc = JSONEncoder()
        if pretty { enc.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try enc.encode(self)
    }

    /// Convert to String (UTF-8).
    func toJSONString(pretty: Bool = false) throws -> String {
        let data = try toJSONData(pretty: pretty)
        return String(decoding: data, as: UTF8.self)
    }

    /// Convenience casts.
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i):    return String(i)
        case .int64(let i):  return String(i)
        case .double(let d): return String(d)
        case .bool(let b):   return String(b)
        default:             return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i):   return i
        case .int64(let i): return (i >= Int64(Int.min) && i <= Int64(Int.max)) ? Int(i) : nil
        case .double(let d): return Int(exactly: d)
        case .string(let s): return Int(s)
        case .bool(let b):   return b ? 1 : 0
        default:             return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b):    return b
        case .int(let i):     return i != 0
        case .int64(let i):   return i != 0
        case .double(let d):  return d != 0
        case .string(let s):  return (s as NSString).boolValue
        default:              return nil
        }
    }
}

// MARK: - Tiny utility for ad-hoc Encodable wrapping

@usableFromInline
struct AnyEncodable: Encodable {
    @usableFromInline let encodeFunc: (Encoder) throws -> Void

    @inlinable
    init<T: Encodable>(_ wrapped: T) {
        self.encodeFunc = wrapped.encode(to:)
    }

    @inlinable
    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
