// Copyright (c) 2026 DOTS
// Standalone plugin contract for Dots Harness.

import Foundation
import SwiftUI

/// Live host handle. Never serialize this object.
@MainActor
public protocol PluginContext: AnyObject {
    var rowId: String { get }
    var pluginId: String { get }
    var pluginDirectory: URL? { get }
    var plane: PluginPlane { get }
    var trust: PluginTrust { get }
    var config: JSONObject { get }

    func get(_ name: String) -> Any?
    func require(_ name: String) throws -> Any
    func provide(_ name: String, _ value: Any)

    func effect(_ undo: @escaping () -> Void)
    @discardableResult
    func on(_ event: String, _ handler: @escaping (Any?) -> Void) -> () -> Void

    var tools: ToolRegistry { get }
    var prompt: PromptRegistry { get }
    var slots: SlotRegistry { get }
    var settings: SettingsRegistry { get }
    var events: EventBus { get }
}

public protocol HarnessPlugin: AnyObject {
    static var manifest: PluginManifest { get }
    @MainActor
    func apply(_ ctx: PluginContext) throws
}

/// Bundled plugins implement this so the catalog can construct them.
public protocol DefaultPlugin: HarnessPlugin {
    init()
}

public extension DefaultPlugin {
    static func create() -> HarnessPlugin { Self() }
}

/// Manifest-only plugin used when the user drops `plugin.yml` without a dylib.
public final class ManifestPlugin: HarnessPlugin {
    public static var manifest: PluginManifest {
        PluginManifest(id: "dots.manifest-placeholder", name: "Manifest", version: "0.0.0", plane: .session)
    }

    public let resolved: PluginManifest
    public let directory: URL?

    public init(manifest: PluginManifest, directory: URL?) {
        self.resolved = manifest
        self.directory = directory
    }

    public func apply(_ ctx: PluginContext) throws {
        applyPromptSection(ctx)
        try applyTools(ctx)
        applyPanels(ctx)
    }

    @MainActor
    private func applyPromptSection(_ ctx: PluginContext) {
        guard let spec = resolved.promptSection else { return }
        let text: String
        if let raw = spec.text, !raw.isEmpty {
            text = raw
        } else if let file = spec.file, let directory {
            text = (try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)) ?? ""
        } else {
            text = ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ctx.prompt.section(name: spec.name, order: spec.order, text: text)
    }

    @MainActor
    private func applyTools(_ ctx: PluginContext) throws {
        for spec in resolved.tools {
            if spec.action.needsTrust, ctx.trust == .untrusted {
                throw PluginError.applyFailed("tool \(spec.name): \(spec.action.kind) actions need a trusted plugin")
            }
            let action = spec.action
            ctx.tools.register(
                name: spec.name,
                description: spec.description,
                parameters: spec.parameters.map {
                    ToolParameter(name: $0.name, type: $0.type, description: $0.description, required: $0.required)
                }
            ) { [weak ctx] args in
                switch action.kind {
                case "emit":
                    guard let event = action.event else { throw PluginError.applyFailed("emit action needs an event") }
                    let payload = DeclarativeShell.subst(action.payload ?? "", args)
                    await MainActor.run { ctx?.events.emit(event, payload) }
                    return "emitted \(event)"
                case "shell":
                    return try DeclarativeShell.shell(action.command ?? [], args)
                case "http":
                    return try await DeclarativeShell.http(action, args)
                default:
                    throw PluginError.applyFailed("unknown action kind \(action.kind)")
                }
            }
        }
    }

    @MainActor
    private func applyPanels(_ ctx: PluginContext) {
        for panel in resolved.panels {
            ctx.slots.inject(panel.slot, id: panel.id, order: panel.order, label: panel.label) {
                PanelView(node: panel.body, ctx: ctx)
            }
        }
    }
}
