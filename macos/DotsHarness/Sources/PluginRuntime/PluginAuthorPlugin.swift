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
        // Source drafts stay outside the runtime catalog. Only signed marketplace
        // artifacts are eligible for loading or explicit trust acceptance.
        let drafts = catalog.paths.root.appendingPathComponent("plugin-drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)

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
            description: "Write a native plugin source draft under the non-loadable local plugin-drafts directory.",
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
            let folder = drafts.appendingPathComponent(id, isDirectory: true)
            guard Self.isInside(folder, root: drafts) else { throw PluginError.package("draft path escaped its directory") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, contents) in files {
                guard Self.isSafeRelative(name) else { throw PluginError.package("unsafe file path \(name)") }
                let target = folder.appendingPathComponent(name)
                guard Self.isInside(target, root: folder), !Self.hasSymlink(target, under: folder) else {
                    throw PluginError.package("draft path is unsafe: \(name)")
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: target, atomically: true, encoding: .utf8)
            }
            return "saved native draft \(id) with \(files.count) file(s) under \(folder.path); build and sign it in Marketplace before installing"
        }

        ctx.tools.register(
            name: "plugin.validate",
            description: "Validate a native plugin draft without loading untrusted code.",
            parameters: [ToolParameter(name: "id", type: "string", description: "plugin id")]
        ) { args in
            let id = args["id"] ?? ""
            guard Self.isSafeID(id) else { return "error: unsafe plugin id" }
            let folder = drafts.appendingPathComponent(id, isDirectory: true)
            guard Self.isInside(folder, root: drafts), !Self.hasSymlink(folder, under: drafts),
                  let manifestData = try? Data(contentsOf: folder.appendingPathComponent("plugin.yml")),
                  let manifestText = String(data: manifestData, encoding: .utf8),
                  let manifest = try? MiniYAML.decode(PluginManifest.self, from: manifestText), manifest.id == id else {
                return "error: no valid native draft named \(id)"
            }
            guard manifest.runtime.lowercased() == "native", let library = manifest.library,
                  Self.isSafeRelative(library),
                  let irData = try? Data(contentsOf: folder.appendingPathComponent("plugin.ir.json")),
                  (try? JSONSerialization.jsonObject(with: irData)) != nil else {
                return "error: draft needs runtime: native, a safe library entry, and valid plugin.ir.json"
            }
            return "ok — native source draft is structurally valid; build/sign it through Marketplace CI before installation"
        }

        ctx.tools.register(name: "plugin.list", description: "List native source drafts; drafts are not installed or loadable.", parameters: []) { _ in
            let folders = (try? FileManager.default.contentsOfDirectory(at: drafts, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            let rows = folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder -> String? in
                guard Self.isInside(folder, root: drafts), !Self.hasSymlink(folder, under: drafts) else { return nil }
                guard let text = try? String(contentsOf: folder.appendingPathComponent("plugin.yml"), encoding: .utf8),
                      let manifest = try? MiniYAML.decode(PluginManifest.self, from: text) else { return "\(folder.lastPathComponent) [invalid draft]" }
                return "\(manifest.id) v\(manifest.version) [source draft; not loadable]"
            }
            return rows.isEmpty ? "no plugin drafts found" : rows.joined(separator: "\n")
        }

        ctx.tools.register(
            name: "plugin.remove",
            description: "Delete a local native plugin draft.",
            parameters: [ToolParameter(name: "id", type: "string", description: "plugin id")]
        ) { args in
            let id = args["id"] ?? ""
            guard Self.isSafeID(id) else { throw PluginError.package("unsafe plugin id \(id)") }
            let folder = drafts.appendingPathComponent(id, isDirectory: true)
            guard Self.isInside(folder, root: drafts), !Self.hasSymlink(folder, under: drafts),
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
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("..") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    private static func hasSymlink(_ url: URL, under root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        var current = url.standardizedFileURL
        while current.path != base {
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { return true }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path, parent.path == base || parent.path.hasPrefix(base + "/") else { return true }
            current = parent
        }
        return false
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
    translated to C# automatically. Local drafts are stored under Application Support/
    DotsHarness/plugin-drafts, outside the runtime catalog. Release versions and licenses are immutable.
    """
}
