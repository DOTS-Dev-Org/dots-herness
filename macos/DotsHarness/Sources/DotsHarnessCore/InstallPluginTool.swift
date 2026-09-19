// Copyright (c) 2026 DOTS
// Agent tool boundary for plugin installation. Native code is never written
// straight into the live catalog by an agent; signed Marketplace packages are
// the only supported installation path.

import Foundation
import HarnessPluginKit
import PluginRuntime

public enum InstallPluginTool {
    public static let name = "install_plugin"

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Install a native plugin through the signed Marketplace flow. This agent tool \
        intentionally refuses to write executable plugin code into the live catalog. \
        Publish a source/IR package, wait for the platform build and signature, then \
        install it from Marketplace after the user accepts the native-code warning. \
        JavaScript and manifest-only plugins are not supported.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Plugin id, also the folder name. Reverse-DNS, no slashes or spaces."),
                ]),
                "files": .object([
                    "type": .string("object"),
                    "description": .string(
                        "Map of relative file path to text content. Must include \"plugin.yml\". "
                            + "Subfolders allowed (\"assets/x.txt\"); no absolute paths or \"..\"."
                    ),
                ]),
                "summary": .object([
                    "type": .string("string"),
                    "description": .string("Optional one line on what the plugin does."),
                ]),
            ]),
            "required": .array([.string("id"), .string("files")]),
        ])
    )

    public struct Outcome: Sendable, Equatable {
        public let installed: Bool
        public let notice: String
    }

    /// Never throws — a bad call is reported back to the model, not failed.
    public static func write(_ arguments: String, into pluginsDir: URL) -> Outcome {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Outcome(installed: false, notice: malformedNotice)
        }
        let id = (object["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeComponent(id) else {
            return Outcome(installed: false, notice: "Not installed: \"\(id)\" is not a usable plugin id (no slashes, spaces, or \"..\").")
        }
        guard let files = object["files"] as? [String: Any], !files.isEmpty else {
            return Outcome(installed: false, notice: malformedNotice)
        }
        var textFiles: [String: String] = [:]
        for (rawPath, value) in files {
            guard let content = value as? String else {
                return Outcome(installed: false, notice: "Not installed: \"\(rawPath)\" content must be a string.")
            }
            guard isSafeRelativePath(rawPath) else {
                return Outcome(installed: false, notice: "Not installed: \"\(rawPath)\" is not a safe relative path.")
            }
            textFiles[rawPath] = content
        }
        guard let manifestText = textFiles["plugin.yml"] else {
            return Outcome(installed: false, notice: "Not installed: files must include \"plugin.yml\".")
        }
        let manifest: PluginManifest
        do {
            manifest = try MiniYAML.decode(PluginManifest.self, from: manifestText)
        } catch {
            return Outcome(installed: false, notice: "Not installed: plugin.yml did not parse — \(error.localizedDescription)")
        }
        _ = manifest
        _ = pluginsDir
        return Outcome(
            installed: false,
            notice: "Not installed: native plugin packages must come from Marketplace after CI build, DOTS signature verification, and explicit trust acceptance."
        )
    }

    public static let malformedNotice =
        "That call was not usable. Send `id` and a non-empty `files` map that includes \"plugin.yml\"."

    static func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        if value.hasPrefix(".") { return false }
        if value.contains("/") || value.contains("\\") { return false }
        if value.contains("..") { return false }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }
        return true
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), value.count <= 400 else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && part != ".." && part != "." && !part.hasPrefix(".")
        }
    }
}
