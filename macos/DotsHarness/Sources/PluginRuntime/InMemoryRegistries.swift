// Copyright (c) 2026 DOTS
// In-memory plugin registries for Dots Harness.

import Foundation
import SwiftUI
import HarnessPluginKit

@MainActor
public final class InMemoryPromptRegistry: PromptRegistry {
    private var items: [PromptSection] = []

    public init() {}

    public func retractOwner(_ owner: String) {
        items.removeAll { $0.owner == owner }
    }

    @discardableResult
    public func section(name: String, order: Int, text: String) -> () -> Void {
        let owner = FiberLocal.owner
        items.removeAll { $0.name == name && $0.owner == owner }
        items.append(PromptSection(name: name, order: order, text: text, owner: owner))
        return { [weak self] in
            self?.items.removeAll { $0.name == name && $0.owner == owner }
        }
    }

    public func assembledText() -> String {
        items.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n\n")
    }

    public func sections() -> [PromptSection] {
        items.sorted { $0.order < $1.order }
    }
}

@MainActor
public final class InMemoryToolRegistry: ToolRegistry {
    private struct Stored {
        var meta: RegisteredTool
        var execute: ([String: String]) async throws -> String
    }

    private var items: [String: Stored] = [:]

    public init() {}

    public func retractOwner(_ owner: String) {
        items = items.filter { $0.value.meta.owner != owner }
    }

    @discardableResult
    public func register(
        name: String,
        description: String,
        parameters: [ToolParameter],
        execute: @escaping ([String: String]) async throws -> String
    ) -> () -> Void {
        let owner = FiberLocal.owner
        items[name] = Stored(
            meta: RegisteredTool(name: name, description: description, parameters: parameters, owner: owner),
            execute: execute
        )
        return { [weak self] in
            if self?.items[name]?.meta.owner == owner {
                self?.items.removeValue(forKey: name)
            }
        }
    }

    public func tools() -> [RegisteredTool] {
        items.values.map(\.meta).sorted { $0.name < $1.name }
    }

    public func call(_ name: String, arguments: [String: String]) async throws -> String {
        guard let stored = items[name] else {
            throw PluginError.applyFailed("unknown tool \(name)")
        }
        return try await stored.execute(arguments)
    }
}

@MainActor
public final class InMemorySlotRegistry: ObservableObject, SlotRegistry {
    @Published private var items: [SlotRegistration] = []

    public init() {}

    public func retractOwner(_ owner: String) {
        items.removeAll { $0.owner == owner }
    }

    @discardableResult
    public func inject(
        _ slot: String,
        id: String,
        order: Int,
        label: String,
        @ViewBuilder view: () -> some View
    ) -> () -> Void {
        let owner = FiberLocal.owner
        if let existing = items.first(where: { $0.slot == slot && $0.id == id && $0.owner != owner }) {
            assertionFailure("slot collision \(slot)/\(existing.id)")
        }
        items.removeAll { $0.slot == slot && $0.id == id && $0.owner == owner }
        items.append(SlotRegistration(id: id, slot: slot, order: order, label: label, owner: owner, view: AnyView(view())))
        return { [weak self] in
            self?.items.removeAll { $0.slot == slot && $0.id == id && $0.owner == owner }
        }
    }

    public func occupants(in slot: String) -> [SlotRegistration] {
        items.filter { $0.slot == slot }.sorted { $0.order < $1.order }
    }

    public func all() -> [SlotRegistration] {
        items.sorted { lhs, rhs in
            (lhs.slot, lhs.order, lhs.id) < (rhs.slot, rhs.order, rhs.id)
        }
    }
}

@MainActor
public final class InMemorySettingsRegistry: SettingsRegistry {
    private var values: [String: JSONValue]
    private let persist: (([String: JSONValue]) -> Void)?

    public init(values: [String: JSONValue] = [:], persist: (([String: JSONValue]) -> Void)? = nil) {
        self.values = values
        self.persist = persist
    }

    public func get(_ key: String) -> JSONValue? { values[key] }

    public func set(_ key: String, _ value: JSONValue) {
        values[key] = value
        persist?(values)
    }

    public func snapshot() -> [String: JSONValue] { values }
}

@MainActor
public final class InMemoryEventBus: EventBus {
    private var handlers: [String: [UUID: (Any?) -> Void]] = [:]

    public init() {}

    @discardableResult
    public func on(_ name: String, _ handler: @escaping (Any?) -> Void) -> () -> Void {
        let token = UUID()
        handlers[name, default: [:]][token] = handler
        return { [weak self] in
            self?.handlers[name]?[token] = nil
        }
    }

    public func emit(_ name: String, _ payload: Any?) {
        handlers[name]?.values.forEach { $0(payload) }
    }
}

enum FiberLocal {
    @TaskLocal static var owner: String = "host"
}
