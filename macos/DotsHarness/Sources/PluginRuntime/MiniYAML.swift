// Copyright (c) 2026 DOTS
// Small YAML reader for Dots Harness plugin manifests.

import Foundation
import HarnessPluginKit

/// Indentation-based YAML subset for composition files. Not a full YAML 1.2
/// engine — enough for host.yml, presets, plugin.yml, and patch
/// patch arrays.
public enum MiniYAML {
    public static func loadValue(from text: String) throws -> JSONValue {
        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        var index = 0
        skipEmpty(&index, lines)
        guard index < lines.count else { return .null }
        return try parseNode(lines: lines, index: &index, minIndent: -1)
    }

    public static func loadObject(from text: String) throws -> JSONObject {
        let value = try loadValue(from: text)
        if case .object(let object) = value { return object }
        if case .null = value { return [:] }
        throw PluginError.invalidComposition("expected a mapping at document root")
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let value = try loadValue(from: text)
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public static func loadPatches(from text: String) throws -> [CompositionPatch] {
        let value = try loadValue(from: text)
        guard case .array(let items) = value else {
            if case .object = value { return [] }
            if case .null = value { return [] }
            throw PluginError.invalidComposition("patch file must be a YAML array")
        }
        return try items.map(parsePatch)
    }

    private static func parsePatch(_ value: JSONValue) throws -> CompositionPatch {
        guard let object = value.object else {
            throw PluginError.invalidComposition("patch entry must be a mapping")
        }
        if let insert = object["insert"] {
            guard case .array(let rows) = insert else {
                throw PluginError.invalidComposition("insert must be an array")
            }
            let data = try JSONEncoder().encode(rows)
            let entries = try JSONDecoder().decode([CompositionEntry].self, from: data)
            return .insert(entries)
        }
        if let id = object["disable"]?.string {
            return .disable(id)
        }
        if let id = object["enable"]?.string {
            return .enable(id)
        }
        if case .object(let configOp) = object["config"] {
            guard let id = configOp["id"]?.string else {
                throw PluginError.invalidComposition("config patch needs id")
            }
            let merge = configOp["merge"]?.object ?? [:]
            return .mergeConfig(id: id, config: merge)
        }
        throw PluginError.invalidComposition("unknown patch operation")
    }

    private static func parseNode(lines: [String], index: inout Int, minIndent: Int) throws -> JSONValue {
        skipEmpty(&index, lines)
        guard index < lines.count else { return .null }
        let (indent, content) = splitIndent(lines[index])
        if indent < minIndent { return .null }
        if content.hasPrefix("- ") || content == "-" {
            return try parseArray(lines: lines, index: &index, indent: indent)
        }
        return try parseMapping(lines: lines, index: &index, indent: indent)
    }

    private static func parseMapping(lines: [String], index: inout Int, indent: Int) throws -> JSONValue {
        var object: JSONObject = [:]
        while index < lines.count {
            skipEmpty(&index, lines)
            guard index < lines.count else { break }
            let (lineIndent, content) = splitIndent(lines[index])
            if lineIndent < indent { break }
            if content.hasPrefix("- ") { break }
            if lineIndent > indent {
                throw PluginError.invalidComposition("unexpected indent at \(content)")
            }
            guard let colon = content.firstIndex(of: ":") else {
                throw PluginError.invalidComposition("expected key: \(content)")
            }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty {
                skipEmpty(&index, lines)
                if index < lines.count {
                    let (nextIndent, nextContent) = splitIndent(lines[index])
                    if nextIndent > indent {
                        if nextContent.hasPrefix("- ") || nextContent == "-" {
                            object[key] = try parseArray(lines: lines, index: &index, indent: nextIndent)
                        } else {
                            object[key] = try parseMapping(lines: lines, index: &index, indent: nextIndent)
                        }
                        continue
                    }
                }
                object[key] = .null
            } else {
                object[key] = parseScalar(rest)
            }
        }
        return .object(object)
    }

    private static func parseArray(lines: [String], index: inout Int, indent: Int) throws -> JSONValue {
        var items: [JSONValue] = []
        while index < lines.count {
            skipEmpty(&index, lines)
            guard index < lines.count else { break }
            let (lineIndent, content) = splitIndent(lines[index])
            if lineIndent < indent { break }
            if !(content.hasPrefix("- ") || content == "-") { break }
            let rest = content == "-" ? "" : String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty {
                items.append(try parseNode(lines: lines, index: &index, minIndent: indent + 1))
            } else if rest.contains(":"), !rest.hasPrefix("{"), !rest.hasPrefix("[") {
                var collected: [String] = [String(repeating: " ", count: indent + 2) + rest]
                while index < lines.count {
                    skipBlankKeep(&index, lines)
                    guard index < lines.count else { break }
                    let (childIndent, child) = splitIndent(lines[index])
                    if child.isEmpty { index += 1; continue }
                    if child.hasPrefix("- ") && childIndent <= indent { break }
                    if childIndent <= indent { break }
                    collected.append(lines[index])
                    index += 1
                }
                var childIndex = 0
                items.append(try parseMapping(lines: collected, index: &childIndex, indent: indent + 2))
            } else {
                items.append(parseScalar(rest))
            }
        }
        return .array(items)
    }

    private static func parseScalar(_ raw: String) -> JSONValue {
        if raw == "~" || raw == "null" { return .null }
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let number = Double(raw), raw.unicodeScalars.allSatisfy({ "0"..."9" ~= Character($0) || $0 == "." || $0 == "-" }) {
            return .number(number)
        }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            return .string(String(raw.dropFirst().dropLast()))
        }
        return .string(raw)
    }

    private static func skipEmpty(_ index: inout Int, _ lines: [String]) {
        while index < lines.count {
            let (_, content) = splitIndent(lines[index])
            if content.isEmpty || content.hasPrefix("#") {
                index += 1
                continue
            }
            break
        }
    }

    private static func skipBlankKeep(_ index: inout Int, _ lines: [String]) {
        while index < lines.count {
            let (_, content) = splitIndent(lines[index])
            if content.isEmpty {
                index += 1
                continue
            }
            break
        }
    }

    private static func splitIndent(_ line: String) -> (Int, String) {
        var indent = 0
        var seen = line.startIndex
        while seen < line.endIndex, line[seen] == " " {
            indent += 1
            seen = line.index(after: seen)
        }
        var content = String(line[seen...])
        if let hash = content.firstIndex(of: "#"), !content.hasPrefix("http") {
            // keep http:// comments-free; strip trailing comments on keys
            if hash != content.startIndex, content[content.index(before: hash)] == " " {
                content = String(content[..<hash]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (indent, content)
    }
}
