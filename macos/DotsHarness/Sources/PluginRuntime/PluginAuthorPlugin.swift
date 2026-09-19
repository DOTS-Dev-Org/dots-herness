// Copyright (c) 2026 DOTS
// Native plugin authoring helper. It creates source/IR drafts only; execution
// happens after the marketplace build, signature verification, and trust gate.

import Foundation
import HarnessPluginKit

public final class PluginAuthorPlugin: DefaultPlugin {
    public static let manifest = PluginManifest(
        id: "dots.plugin-author",
        name: "Plugin Author",
        version: "2.0.0",
        plane: .host,
        inject: ["prompt", "tools"],
        description: "Create and validate native Dots Harness plugin drafts."
    )

    public init() {}

    @MainActor
    public func apply(_ ctx: PluginContext) throws {
        guard let catalog = try ctx.require("catalog") as? PluginCatalog else {
            throw PluginError.missingService("catalog")
        }
        let plugins = catalog.paths.plugins

        ctx.prompt.section(name: "plugin-author", order: 60, text: """
        You can create native Dots Harness plugin drafts. Use plugin.schema for the
        package contract, then plugin.save with plugin.yml, plugin.ir.json, and
        native source files. JavaScript and manifest-only plugins are not supported.
        A draft must be built by the trusted marketplace CI before it can be loaded.
        """)

        ctx.tools.register(name: "plugin.schema", description: "Return the native plugin package format.", parameters: []) { _ in
            Self.schema
        }

        ctx.tools.register(
            name: "plugin.save",
            description: "Write a native plugin source draft under the local plugins directory.",
            parameters: [
                ToolParameter(name: "id", type: "string", description: "Reverse-DNS plugin id, e.g. com.you.thing"),
                ToolParameter(name: "files", type: "string", description: "JSON object of relative path to text content; plugin.yml and plugin.ir.json are required."),
            ]
        ) { args in
            let id = args["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard Self.isSafeID(id) else { throw PluginError.package("unsafe plugin id \(id)") }
            guard let raw = args["files"]?.data(using: .utf8),
                  let files = try? JSONDecoder().decode([String: String].self, from: raw),
                  files["plugin.yml"] != nil,
                  files["plugin.ir.json"] != nil else {
                throw PluginError.package("files must include plugin.yml and plugin.ir.json")
            }
            let folder = plugins.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, contents) in files {
                guard Self.isSafeRelative(name) else { throw PluginError.package("unsafe file path \(name)") }
                let target = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: target, atomically: true, encoding: .utf8)
            }
            catalog.refresh()
            return "saved native draft \(id) with \(files.count) file(s); build it in Marketplace before enabling it"
        }

        ctx.tools.register(
            name: "plugin.validate",
            description: "Validate a native plugin draft without loading untrusted code.",
            parameters: [ToolParameter(name: "id", type: "string", description: "plugin id")]
        ) { args in
            let id = args["id"] ?? ""
            catalog.refresh()
            guard let entry = catalog.entries.first(where: { $0.manifest.id == id }) else {
                return "error: no plugin named \(id)"
            }
            if let broken = entry.broken { return "native validation: \(broken)" }
            guard let folder = entry.url else { return "error: plugin has no source folder" }
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("plugin.ir.json").path) else {
                return "error: plugin.ir.json is missing"
            }
            return "ok — native package is ready for marketplace CI; runtime loading requires a signed library and explicit trust"
        }

        ctx.tools.register(name: "plugin.list", description: "List installed native plugin drafts.", parameters: []) { _ in
            catalog.refresh()
            if catalog.entries.isEmpty { return "no plugins installed" }
            return catalog.entries.map {
                "\($0.manifest.id) v\($0.manifest.version) [\($0.kind.rawValue)/\($0.trust.rawValue)]"
                    + ($0.broken.map { " BROKEN: \($0)" } ?? "")
            }.joined(separator: "\n")
        }

        ctx.tools.register(
            name: "plugin.remove",
            description: "Delete a local native plugin draft.",
            parameters: [ToolParameter(name: "id", type: "string", description: "plugin id")]
        ) { args in
            let id = args["id"] ?? ""
            guard Self.isSafeID(id) else { throw PluginError.package("unsafe plugin id \(id)") }
            let folder = plugins.appendingPathComponent(id, isDirectory: true)
            guard folder.standardizedFileURL.path.hasPrefix(plugins.standardizedFileURL.path),
                  FileManager.default.fileExists(atPath: folder.path) else {
                throw PluginError.package("no such plugin \(id)")
            }
            try FileManager.default.removeItem(at: folder)
            catalog.refresh()
            return "removed \(id)"
        }
    }

    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("..") && id != "." && !id.hasPrefix(".")
    }

    static func isSafeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("..") && !path.contains("\0")
    }

    static let schema = """
    Native plugin package:

      plugin.yml
      plugin.ir.json
      license
      source/macos/       # Swift/SwiftUI + SwiftPM dynamic-library source
      source/windows/     # C# + WPF + IHarnessPlugin source
      source/linux/       # C# + Avalonia + IHarnessPlugin source
      artifacts/<platform>/<architecture>/

    plugin.yml must contain id, name, version, abi, plane, runtime: native, and
    library. plugin.ir.json is the shared IR for prompt sections, typed tools,
    events, settings/state, and supported panel components. Platform-specific
    source stays under its target directory; arbitrary SwiftUI cannot be
    translated to C# automatically. Release versions and licenses are immutable.
    """
}
