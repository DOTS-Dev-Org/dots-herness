// Copyright (c) 2026 DOTS
// Lets the harness agent author declarative / JS plugins from chat: it writes
// a folder under the plugins directory, then validates it by mounting a probe
// host. Iteration loop is the agent's normal tool loop — no bespoke LLM call.

import Foundation
import HarnessPluginKit

public final class PluginAuthorPlugin: DefaultPlugin {
    public static let manifest = PluginManifest(
        id: "dots.plugin-author",
        name: "Plugin Author",
        version: "1.0.0",
        plane: .host,
        inject: ["prompt", "tools"],
        description: "Author and validate Dots Harness plugins from chat."
    )

    public init() {}

    @MainActor
    public func apply(_ ctx: PluginContext) throws {
        guard let catalog = try ctx.require("catalog") as? PluginCatalog else {
            throw PluginError.missingService("catalog")
        }
        let plugins = catalog.paths.plugins

        ctx.prompt.section(name: "plugin-author", order: 60, text: """
        You can build Dots Harness plugins for the user. Call `plugin.schema` for the
        exact file format. Write the plugin with `plugin.save`, then `plugin.validate`;
        fix issues and repeat until it returns `ok`. Prefer declarative plugins (no
        code); use a `main: plugin.js` script only when logic is required.
        """)

        ctx.tools.register(name: "plugin.schema", description: "Return the plugin file format.", parameters: []) { _ in
            Self.schema
        }

        ctx.tools.register(
            name: "plugin.save",
            description: "Write a plugin folder. `files` is a JSON object of relativePath -> file contents; must include plugin.yml.",
            parameters: [
                ToolParameter(name: "id", type: "string", description: "plugin id, e.g. com.you.thing"),
                ToolParameter(name: "files", type: "string", description: "JSON: {\"plugin.yml\": \"...\", \"prompt.md\": \"...\"}"),
            ]
        ) { args in
            let id = args["id"] ?? ""
            guard Self.isSafeID(id) else { throw PluginError.package("unsafe plugin id \(id)") }
            guard let raw = args["files"]?.data(using: .utf8),
                  let files = try? JSONDecoder().decode([String: String].self, from: raw),
                  files["plugin.yml"] != nil else {
                throw PluginError.package("files must be a JSON object containing plugin.yml")
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
            return "saved \(files.count) file(s) to \(id). Run plugin.validate next."
        }

        ctx.tools.register(
            name: "plugin.validate",
            description: "Mount the plugin in a throwaway host and report issues or ok.",
            parameters: [ToolParameter(name: "id", type: "string", description: "plugin id")]
        ) { args in
            let id = args["id"] ?? ""
            catalog.refresh()
            if let entry = catalog.entries.first(where: { $0.manifest.id == id }), let broken = entry.broken {
                return "manifest error: \(broken)"
            }
            let probe = PluginHost(catalog: catalog)
            let issues = probe.mount(CompositionDocument(plane: .session, entries: [
                CompositionEntry(id: "probe", plugin: id),
            ]))
            defer { probe.unmountAll() }
            if !issues.isEmpty {
                return "issues:\n" + issues.map { "- \($0.message)" }.joined(separator: "\n")
            }
            let tools = probe.tools.tools().map(\.name).sorted()
            let sections = probe.prompt.sections().map(\.name)
            return "ok — prompt sections \(sections), tools \(tools), panels \(probe.slots.all().count)"
        }

        ctx.tools.register(name: "plugin.list", description: "List installed plugins.", parameters: []) { _ in
            catalog.refresh()
            if catalog.entries.isEmpty { return "no plugins installed" }
            return catalog.entries.map {
                "\($0.manifest.id) v\($0.manifest.version) [\($0.kind.rawValue)/\($0.trust.rawValue)]"
                    + ($0.broken.map { " BROKEN: \($0)" } ?? "")
            }.joined(separator: "\n")
        }

        ctx.tools.register(
            name: "plugin.remove",
            description: "Delete an installed plugin folder.",
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
    A plugin is a folder under the plugins directory named exactly its `id`, with a
    `plugin.yml` manifest. Three kinds:

    1. DECLARATIVE (preferred, no code). plugin.yml:

       id: com.you.thing          # folder name == id
       name: Thing
       version: 0.1.0
       plane: session             # session (per chat) | host (global)
       runtime: declarative
       promptSection:             # optional system-prompt text
         name: thing:note
         order: 40
         text: "One sentence the model should know."
       tools:                     # optional
         - name: thing:do
           description: what it does
           parameters:
             - { name: who, type: string, description: "", required: true }
           action:
             kind: emit           # emit (always allowed) | shell | http (need trusted)
             event: thing/done
             payload: "{who}"     # {param} substitution
       panels:                    # optional SwiftUI, described as a node tree
         - slot: conversation.composer.accessory   # or shell.overlay, settings.sections, plugins.detail, shell.sidebar.footer
           id: main
           order: 10
           label: Thing
           body:
             type: vstack         # vstack|hstack|text|button|field|toggle|spacer|image
             children:
               - { type: text, text: "Hello" }
               - { type: field, key: thing.note, placeholder: "note" }
               - { type: toggle, key: thing.on, label: "On" }
               - { type: button, label: "Go", tool: thing:do, args: { who: world } }

    2. JS. Add `main: plugin.js`; ship a plugin.js with a global `apply(h)`:
       function apply(h) {
         h.prompt("thing:note", 40, "text");
         h.tool("thing:do", "desc", function (args) { return "result string"; });
         h.on("evt", function (p) { h.emit("evt2", p); });
         h.get("key"); h.set("key", value);
         h.panel("conversation.composer.accessory", "main", 10, "Thing", { type: "vstack", children: [ ... ] });
       }
       Sandboxed: no fs, no network, no timers. Tool callbacks return synchronously.

    3. NATIVE (compiled Swift dylib) — out of scope here; ships via the marketplace.

    Workflow: plugin.save (files JSON incl. plugin.yml) -> plugin.validate -> fix -> repeat.
    """
}
