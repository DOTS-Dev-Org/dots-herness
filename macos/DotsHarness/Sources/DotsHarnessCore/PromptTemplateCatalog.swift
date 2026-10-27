// Copyright (c) 2026 DOTS
// User-authored Markdown prompt templates.

import Combine
import Foundation

public struct PromptTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let description: String
    public let argumentHint: String
    public let body: String
    public let path: String

    public init(id: String, title: String, description: String, argumentHint: String, body: String, path: String) {
        self.id = id
        self.title = title
        self.description = description
        self.argumentHint = argumentHint
        self.body = body
        self.path = path
    }
}

/// Loads lightweight, user-authored Markdown templates from the app and project folders.
/// Project templates replace app templates with the same filename.
@MainActor
public final class PromptTemplateCatalog: ObservableObject {
    @Published public private(set) var templates: [PromptTemplate] = []

    public let globalDirectory: URL

    public init(globalDirectory: URL) {
        self.globalDirectory = globalDirectory
        refresh(workspacePath: nil)
    }

    public func refresh(workspacePath: String?) {
        let normalizedWorkspace = workspacePath.flatMap { path -> String? in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        var byID: [String: PromptTemplate] = [:]
        for template in Self.readTemplates(in: globalDirectory) {
            byID[template.id] = template
        }
        if let normalizedWorkspace {
            let projectDirectory = Self.projectDirectory(workspacePath: normalizedWorkspace)
            for template in Self.readTemplates(in: projectDirectory) {
                byID[template.id] = template
            }
        }
        templates = byID.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Expands only namespaced template commands (for example `/template-review`).
    /// Ordinary slash commands and skill commands are left untouched.
    public func expand(_ prompt: String, workspacePath: String?) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { return nil }
        let commandEnd = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        let command = String(trimmed[..<commandEnd])
        guard command.hasPrefix("/template-") else { return nil }

        refresh(workspacePath: workspacePath)
        let id = String(command.dropFirst("/template-".count)).lowercased()
        guard let template = templates.first(where: { $0.id == id }) else { return nil }
        let rawArguments = String(trimmed[commandEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = Self.splitArguments(rawArguments)
        return Self.substitute(template.body, arguments: arguments)
    }

    /// Creates and returns the folder currently used for project templates, or the app folder
    /// when the conversation has no workspace.
    public func directoryToOpen(workspacePath: String?) throws -> URL {
        let directory: URL
        if let workspacePath, !workspacePath.isEmpty {
            directory = Self.projectDirectory(workspacePath: workspacePath)
        } else {
            directory = globalDirectory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func projectDirectory(workspacePath: String) -> URL {
        URL(fileURLWithPath: workspacePath, isDirectory: true)
            .appendingPathComponent(".dotsherness", isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
    }

    private static func readTemplates(in directory: URL) -> [PromptTemplate] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap(readTemplate(at:))
    }

    private static func readTemplate(at url: URL) -> PromptTemplate? {
        let id = url.deletingPathExtension().lastPathComponent.lowercased()
        let fileValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard !id.isEmpty,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }),
              fileValues?.isRegularFile == true,
              fileValues?.isSymbolicLink != true,
              let fileSize = fileValues?.fileSize,
              fileSize <= 128 * 1024,
              let file = try? String(contentsOf: url, encoding: .utf8),
              file.utf8.count <= 128 * 1024 else { return nil }

        let (metadata, body) = splitFrontmatter(file)
        let metadataName = metadata["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = metadataName.isEmpty
            ? id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
            : metadataName
        let description = metadata["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let argumentHint = metadata["argument-hint"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return PromptTemplate(
            id: id,
            title: title,
            description: description,
            argumentHint: argumentHint,
            body: content,
            path: url.path
        )
    }

    private static func splitFrontmatter(_ file: String) -> ([String: String], String) {
        var lines = file.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return ([:], file)
        }
        lines.removeFirst()
        guard let closing = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            return ([:], file)
        }
        var metadata: [String: String] = [:]
        for line in lines[..<closing] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if ["name", "description", "argument-hint"].contains(key) {
                metadata[key] = unquote(value)
            }
        }
        return (metadata, lines[(closing + 1)...].joined(separator: "\n"))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              (first == "\"" && value.last == "\"") || (first == "'" && value.last == "'") else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var started = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                started = true
            } else if character == "\\", quote != "'" {
                escaping = true
                started = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                started = true
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started {
                    result.append(current)
                    current = ""
                    started = false
                }
            } else {
                current.append(character)
                started = true
            }
        }
        if escaping { current.append("\\") }
        if started { result.append(current) }
        return result
    }

    private static func substitute(_ body: String, arguments: [String]) -> String {
        let pattern = #"\$\{(@|ARGUMENTS|\d+)(?::-([^}]*))?\}|\$(ARGUMENTS|@|\d+)(?![A-Za-z0-9_])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return body }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = expression.matches(in: body, range: range)
        var result = body
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            let nameRange = match.range(at: 1).location == NSNotFound ? match.range(at: 3) : match.range(at: 1)
            guard let capturedName = Range(nameRange, in: result) else { continue }
            let name = String(result[capturedName])
            let defaultRange = match.range(at: 2)
            let defaultValue = defaultRange.location == NSNotFound
                ? nil
                : Range(defaultRange, in: result).map { String(result[$0]) }
            let value: String
            if name == "@" || name == "ARGUMENTS" {
                let joined = arguments.joined(separator: " ")
                value = joined.isEmpty ? (defaultValue ?? "") : joined
            } else if let index = Int(name), index > 0, arguments.indices.contains(index - 1) {
                let argument = arguments[index - 1]
                value = argument.isEmpty ? (defaultValue ?? "") : argument
            } else {
                value = defaultValue ?? ""
            }
            result.replaceSubrange(fullRange, with: value)
        }
        return result
    }
}
