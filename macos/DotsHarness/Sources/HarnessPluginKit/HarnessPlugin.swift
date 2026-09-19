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
