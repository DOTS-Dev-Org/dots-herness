// Copyright (c) 2026 DOTS
// Plugin host runtime for Dots Harness.

import Foundation
import HarnessPluginKit

@MainActor
public final class LivePluginContext: PluginContext {
    public let rowId: String
    public let pluginId: String
    public let plane: PluginPlane
    public let trust: PluginTrust
    public let config: JSONObject
    public let tools: ToolRegistry
    public let prompt: PromptRegistry
    public let slots: SlotRegistry
    public let settings: SettingsRegistry
    public let events: EventBus

    private let services: ServiceRealm
    private var disposers: [() -> Void] = []

    init(
        rowId: String,
        pluginId: String,
        plane: PluginPlane,
        trust: PluginTrust,
        config: JSONObject,
        services: ServiceRealm,
        tools: ToolRegistry,
        prompt: PromptRegistry,
        slots: SlotRegistry,
        settings: SettingsRegistry,
        events: EventBus
    ) {
        self.rowId = rowId
        self.pluginId = pluginId
        self.plane = plane
        self.trust = trust
        self.config = config
        self.services = services
        self.tools = tools
        self.prompt = prompt
        self.slots = slots
        self.settings = settings
        self.events = events
    }

    public func get(_ name: String) -> Any? { services.get(name) }

    public func require(_ name: String) throws -> Any {
        guard let value = services.get(name) else { throw PluginError.missingService(name) }
        return value
    }

    public func provide(_ name: String, _ value: Any) {
        services.provide(name, value)
        effect { [weak services] in services?.retract(name) }
    }

    public func effect(_ undo: @escaping () -> Void) {
        disposers.append(undo)
    }

    @discardableResult
    public func on(_ event: String, _ handler: @escaping (Any?) -> Void) -> () -> Void {
        let stop = events.on(event, handler)
        effect(stop)
        return stop
    }

    func dispose() {
        for disposer in disposers.reversed() { disposer() }
        disposers.removeAll()
        if let prompt = prompt as? InMemoryPromptRegistry { prompt.retractOwner(rowId) }
        if let tools = tools as? InMemoryToolRegistry { tools.retractOwner(rowId) }
        if let slots = slots as? InMemorySlotRegistry { slots.retractOwner(rowId) }
    }
}

@MainActor
public final class ServiceRealm {
    private var values: [String: Any] = [:]
    private let parent: ServiceRealm?

    public init(parent: ServiceRealm? = nil, seed: [String: Any] = [:]) {
        self.parent = parent
        self.values = seed
    }

    public func get(_ name: String) -> Any? {
        values[name] ?? parent?.get(name)
    }

    public func provide(_ name: String, _ value: Any) {
        values[name] = value
    }

    public func retract(_ name: String) {
        values.removeValue(forKey: name)
    }

    public var publishedNames: [String] { Array(values.keys) }
}

public struct MountedFiber: Identifiable, Sendable {
    public var id: String
    public var pluginId: String
    public var status: String
    public var isolate: [String: Bool]
}

@MainActor
public final class PluginHost: ObservableObject {
    public let tools: InMemoryToolRegistry
    public let prompt: InMemoryPromptRegistry
    public let slots: InMemorySlotRegistry
    public let settings: InMemorySettingsRegistry
    public let events: InMemoryEventBus

    @Published public private(set) var fibers: [MountedFiber] = []
    @Published public private(set) var issues: [MountIssue] = []

    private let root: ServiceRealm
    private var contexts: [String: LivePluginContext] = [:]
    private let catalog: PluginCatalog

    public init(catalog: PluginCatalog, settings: InMemorySettingsRegistry? = nil) {
        self.catalog = catalog
        self.tools = InMemoryToolRegistry()
        self.prompt = InMemoryPromptRegistry()
        self.slots = InMemorySlotRegistry()
        self.settings = settings ?? InMemorySettingsRegistry()
        self.events = InMemoryEventBus()
        self.root = ServiceRealm(seed: [
            "tools": tools,
            "prompt": prompt,
            "slots": slots,
            "settings": self.settings,
            "events": events,
        ])
    }

    public func provideService(_ name: String, _ value: Any) {
        root.provide(name, value)
    }

    public func unmountAll() {
        for context in contexts.values { context.dispose() }
        contexts.removeAll()
        fibers.removeAll()
        issues.removeAll()
    }

    @discardableResult
    public func mount(_ document: CompositionDocument) -> [MountIssue] {
        unmountAll()
        var nextIssues: [MountIssue] = []
        let enabled = document.entries.filter { !$0.disabled }

        for entry in enabled {
            do {
                let resolved = try catalog.resolve(entry.plugin)
                if !resolved.manifest.abiCompatible {
                    throw PluginError.incompatibleABI(resolved.manifest.abi)
                }
                if resolved.kind == .dylib, resolved.trust == .untrusted {
                    throw PluginError.untrustedLibrary(resolved.manifest.id)
                }
                let plugin = try resolved.make()
                let inject = resolved.manifest.inject
                let isolate = entry.isolate
                let realm: ServiceRealm
                if document.plane == .session, !isolate.isEmpty {
                    realm = ServiceRealm(parent: root)
                } else {
                    realm = root
                }
                for name in inject {
                    if realm.get(name) == nil {
                        throw PluginError.missingService(name)
                    }
                }
                let publishedBefore = Set(root.publishedNames)
                let context = LivePluginContext(
                    rowId: entry.id,
                    pluginId: resolved.manifest.id,
                    plane: document.plane,
                    trust: resolved.trust,
                    config: entry.config,
                    services: realm,
                    tools: tools,
                    prompt: prompt,
                    slots: slots,
                    settings: settings,
                    events: events
                )
                try FiberLocal.$owner.withValue(entry.id) {
                    try plugin.apply(context)
                }
                if document.plane == .session {
                    let published = Set(root.publishedNames).subtracting(publishedBefore)
                    if isolate.isEmpty, !published.isEmpty {
                        context.dispose()
                        throw PluginError.globalService(published.sorted().joined(separator: ", "))
                    }
                }
                contexts[entry.id] = context
                fibers.append(MountedFiber(
                    id: entry.id,
                    pluginId: resolved.manifest.id,
                    status: "active",
                    isolate: isolate
                ))
            } catch {
                nextIssues.append(MountIssue(rowId: entry.id, message: error.localizedDescription))
            }
        }

        if !nextIssues.isEmpty {
            // Failed mount disposes everything it started.
            unmountAll()
            issues = nextIssues
            return nextIssues
        }
        issues = []
        events.emit("plugins/mounted", fibers.map(\.id))
        return []
    }
}
