// Copyright (c) 2026 DOTS
// Plugin registries for Dots Harness.

import Foundation
import SwiftUI

public struct PromptSection: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var order: Int
    public var text: String
    public var owner: String

    public init(name: String, order: Int, text: String, owner: String) {
        self.name = name
        self.order = order
        self.text = text
        self.owner = owner
    }
}

@MainActor
public protocol PromptRegistry: AnyObject {
    @discardableResult
    func section(name: String, order: Int, text: String) -> () -> Void
    func assembledText() -> String
    func sections() -> [PromptSection]
}

public struct ToolParameter: Sendable, Equatable {
    public var name: String
    public var type: String
    public var description: String
    public var required: Bool

    public init(name: String, type: String, description: String, required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

public struct RegisteredTool: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var parameters: [ToolParameter]
    public var owner: String

    public init(name: String, description: String, parameters: [ToolParameter], owner: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.owner = owner
    }
}

@MainActor
public protocol ToolRegistry: AnyObject {
    @discardableResult
    func register(
        name: String,
        description: String,
        parameters: [ToolParameter],
        execute: @escaping ([String: String]) async throws -> String
    ) -> () -> Void
    func tools() -> [RegisteredTool]
    func call(_ name: String, arguments: [String: String]) async throws -> String
}

public struct SlotRegistration: Identifiable {
    public var id: String
    public var slot: String
    public var order: Int
    public var label: String
    public var owner: String
    public var view: AnyView

    public init(id: String, slot: String, order: Int, label: String, owner: String, view: AnyView) {
        self.id = id
        self.slot = slot
        self.order = order
        self.label = label
        self.owner = owner
        self.view = view
    }
}

public enum WellKnownSlot {
    public static let overlay = "shell.overlay"
    public static let sidebarFooter = "shell.sidebar.footer"
    public static let composerAccessory = "conversation.composer.accessory"
    public static let settingsSections = "settings.sections"
    public static let pluginsDetail = "plugins.detail"
}

@MainActor
public protocol SlotRegistry: AnyObject {
    @discardableResult
    func inject(
        _ slot: String,
        id: String,
        order: Int,
        label: String,
        @ViewBuilder view: () -> some View
    ) -> () -> Void
    func occupants(in slot: String) -> [SlotRegistration]
}

@MainActor
public protocol SettingsRegistry: AnyObject {
    func get(_ key: String) -> JSONValue?
    func set(_ key: String, _ value: JSONValue)
}

@MainActor
public protocol EventBus: AnyObject {
    @discardableResult
    func on(_ name: String, _ handler: @escaping (Any?) -> Void) -> () -> Void
    func emit(_ name: String, _ payload: Any?)
}
