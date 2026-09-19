// Copyright (c) 2026 DOTS
// JSON value model for Dots Harness plugin configuration.

import Foundation

/// Lossless JSON tree used for plugin configuration.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(_ key: String) -> JSONValue? {
        object?[key]
    }

    public func string(for key: String, default defaultValue: String) -> String {
        self[key]?.string ?? defaultValue
    }

    public func int(for key: String, default defaultValue: Int) -> Int {
        self[key]?.int ?? defaultValue
    }
}

public typealias JSONObject = [String: JSONValue]

public extension JSONObject {
    func string(for key: String, default defaultValue: String) -> String {
        self[key]?.string ?? defaultValue
    }

    func int(for key: String, default defaultValue: Int) -> Int {
        self[key]?.int ?? defaultValue
    }

    mutating func merge(from other: JSONObject) {
        for (key, value) in other {
            if case .object(let incoming) = value, case .object(let existing)? = self[key] {
                var merged = existing
                merged.merge(from: incoming)
                self[key] = .object(merged)
            } else {
                self[key] = value
            }
        }
    }
}
