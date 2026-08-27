// Copyright (c) 2026 DOTS
// JSON helpers shared by the native agent and provider clients.

import Foundation
import HarnessPluginKit

public enum JSONCodec {
    public static func value(from any: Any?) -> JSONValue {
        guard let any, !(any is NSNull) else { return .null }
        if let value = any as? Bool { return .bool(value) }
        if let value = any as? Int { return .number(Double(value)) }
        if let value = any as? Double { return .number(value) }
        if let value = any as? String { return .string(value) }
        if let value = any as? [Any] { return .array(value.map { self.value(from: $0) }) }
        if let value = any as? [String: Any] {
            return .object(value.mapValues { self.value(from: $0) })
        }
        return .null
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value(from: raw)
    }

    public static func object(from data: Data) throws -> JSONObject {
        let value = try parse(data)
        guard let object = value.object else {
            throw PluginError.applyFailed("expected JSON object")
        }
        return object
    }

    public static func data(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

public extension JSONValue {
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        }
    }

    func textBlocks() -> String {
        switch self {
        case .string(let text):
            return text
        case .array(let items):
            return items.compactMap { item in
                if item["type"]?.string == "reasoning" { return nil }
                return item["text"]?.string
            }.joined()
        case .object(let object):
            if object["type"]?.string == "text" { return object["text"]?.string ?? "" }
            if let content = object["content"] { return content.textBlocks() }
            if let message = object["message"] { return message.textBlocks() }
            if let text = object["text"]?.string { return text }
            return ""
        default:
            return ""
        }
    }
}
