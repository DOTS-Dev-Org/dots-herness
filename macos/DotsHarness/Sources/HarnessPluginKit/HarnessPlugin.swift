// Copyright (c) 2026 DOTS
// Standalone plugin contract for Dots Harness.

import Foundation

/// Live host handle. Never serialize this object.
@MainActor
public protocol PluginContext: AnyObject {
    var rowId: String { get }
    var pluginId: String { get }
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
}
