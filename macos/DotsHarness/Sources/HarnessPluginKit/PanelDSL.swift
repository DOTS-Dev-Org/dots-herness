// Copyright (c) 2026 DOTS
// Declarative plugin DSL: tool specs + panel node tree.
// Authored by users (or an AI) as YAML in `plugin.yml`. No code, no dylib.

import Foundation

/// One declarative tool. `action.kind`:
/// - `emit`  : fire an event on the bus. Always allowed (even untrusted).
/// - `shell` : run argv via `/usr/bin/env`. Requires a trusted plugin.
/// - `http`  : perform a request. Requires a trusted plugin.
public struct ToolSpec: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: [ToolParamSpec]
    public var action: ToolAction

    enum CodingKeys: String, CodingKey { case name, description, parameters, action }

    public init(name: String, description: String = "", parameters: [ToolParamSpec] = [], action: ToolAction) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.action = action
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        parameters = try c.decodeIfPresent([ToolParamSpec].self, forKey: .parameters) ?? []
        action = try c.decode(ToolAction.self, forKey: .action)
    }
}

public struct ToolParamSpec: Codable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var description: String
    public var required: Bool

    enum CodingKeys: String, CodingKey { case name, type, description, required }

    public init(name: String, type: String = "string", description: String = "", required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "string"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }
}

public struct ToolAction: Codable, Sendable, Equatable {
    public var kind: String
    /// shell: argv, each element supports `{param}` substitution.
    public var command: [String]?
    /// http
    public var url: String?
    public var method: String?
    public var body: String?
    /// emit
    public var event: String?
    public var payload: String?

    enum CodingKeys: String, CodingKey { case kind, command, url, method, body, event, payload }

    public init(
        kind: String,
        command: [String]? = nil,
        url: String? = nil,
        method: String? = nil,
        body: String? = nil,
        event: String? = nil,
        payload: String? = nil
    ) {
        self.kind = kind
        self.command = command
        self.url = url
        self.method = method
        self.body = body
        self.event = event
        self.payload = payload
    }

    public var needsTrust: Bool { kind == "shell" || kind == "http" }
}

/// A panel injected into a shell slot. `body` is the root node.
public struct PanelSpec: Codable, Sendable, Equatable {
    public var slot: String
    public var id: String
    public var order: Int
    public var label: String
    public var body: PanelNode

    enum CodingKeys: String, CodingKey { case slot, id, order, label, body }

    public init(slot: String, id: String, order: Int = 0, label: String = "", body: PanelNode) {
        self.slot = slot
        self.id = id
        self.order = order
        self.label = label
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(String.self, forKey: .slot)
        id = try c.decode(String.self, forKey: .id)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        body = try c.decode(PanelNode.self, forKey: .body)
    }
}

/// Flat, tag-based UI node. Trivially Codable and easy for an AI to emit.
///
/// `type`: vstack | hstack | text | button | field | toggle | spacer | image
public struct PanelNode: Codable, Sendable, Equatable {
    public var type: String
    public var text: String?
    public var label: String?
    public var tool: String?
    public var args: [String: String]?
    public var key: String?
    public var placeholder: String?
    public var url: String?
    public var children: [PanelNode]?

    enum CodingKeys: String, CodingKey {
        case type, text, label, tool, args, key, placeholder, url, children
    }

    public init(
        type: String,
        text: String? = nil,
        label: String? = nil,
        tool: String? = nil,
        args: [String: String]? = nil,
        key: String? = nil,
        placeholder: String? = nil,
        url: String? = nil,
        children: [PanelNode]? = nil
    ) {
        self.type = type
        self.text = text
        self.label = label
        self.tool = tool
        self.args = args
        self.key = key
        self.placeholder = placeholder
        self.url = url
        self.children = children
    }
}
