// Copyright (c) 2026 DOTS
// Plugin host runtime for Dots Harness.

import Foundation
import HarnessPluginKit

@MainActor
public final class LivePluginContext: PluginContext {
    public let rowId: String
    public let pluginId: String
    public let pluginDirectory: URL?
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
        pluginDirectory: URL?,
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
        self.pluginDirectory = pluginDirectory
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
        (services.get("provider.imageAdapters") as? ProviderImageAdapterRegistry)?.unregister(owner: rowId)
        if let prompt = prompt as? InMemoryPromptRegistry { prompt.retractOwner(rowId) }
        if let tools = tools as? InMemoryToolRegistry { tools.retractOwner(rowId) }
        if let slots = slots as? InMemorySlotRegistry { slots.retractOwner(rowId) }
    }
}

/// A row's view of services. A child realm keeps the names its row marked
/// `isolate: {name: true}` private to that row; every other name it provides
/// is published through to the parent, where all plugins can see it.
@MainActor
public final class ServiceRealm {
    private var values: [String: Any] = [:]
    private let parent: ServiceRealm?
    private let isolated: Set<String>

    public init(parent: ServiceRealm? = nil, seed: [String: Any] = [:], isolated: Set<String> = []) {
        self.parent = parent
        self.values = seed
        self.isolated = isolated
    }

    public func get(_ name: String) -> Any? {
        values[name] ?? parent?.get(name)
    }

    public func provide(_ name: String, _ value: Any) {
        if let parent, !isolated.contains(name) { parent.provide(name, value) } else { values[name] = value }
    }

    public func retract(_ name: String) {
        if let parent, !isolated.contains(name) { parent.retract(name) } else { values.removeValue(forKey: name) }
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
    public let imageAdapters: ProviderImageAdapterRegistry
    /// Read-only native app data exposed to plugins via `harness.host(topic)`.
    public let hostData: HostDataRegistry

    public func getService<T>(_ name: String, as type: T.Type = T.self) -> T? {
        root.get(name) as? T
    }

    @Published public private(set) var fibers: [MountedFiber] = []
    @Published public private(set) var issues: [MountIssue] = []

    private let root: ServiceRealm
    private var contexts: [String: LivePluginContext] = [:]
    private let catalog: PluginCatalog
    private var configuredToolOwners: [String: String] = [:]
    private var acceptedToolCatalog: [RegisteredTool] = []
    private var mounting = false
    private var needsToolCatalogReconcile = true
    private var reconciledRegistryRevision: UInt64?
    /// Changes only when the provider-visible plugin definitions change.
    public private(set) var toolCatalogRevision: UInt64 = 0
    /// Last lookup result, consumed immediately by prompt-preparation telemetry.
    public private(set) var lastToolCatalogCacheHit = false
    private struct CachedToolCatalog: Codable {
        var owners: [String: String]
        var tools: [RegisteredTool]
    }
    private var toolCatalogURL: URL { catalog.paths.root.appendingPathComponent("plugin-tool-catalog.json") }

    /// Definitions survive disabled or temporarily failed mounts. Closures do
    /// not; ToolRegistry.call still requires a currently mounted implementation.
    public func cacheableTools() -> [RegisteredTool] {
        guard !mounting else {
            lastToolCatalogCacheHit = false
            return acceptedToolCatalog
        }
        let registryRevision = tools.revision
        if !needsToolCatalogReconcile, reconciledRegistryRevision == registryRevision {
            lastToolCatalogCacheHit = true
            return acceptedToolCatalog
        }
        lastToolCatalogCacheHit = false
        let active = tools.tools()
        let activeOwners = Set(fibers.map(\.id))
        let installed = Set(catalog.entries.map { $0.manifest.id })
        let retained = acceptedToolCatalog.filter { tool in
            !activeOwners.contains(tool.owner)
                && configuredToolOwners[tool.owner].map(installed.contains) == true
        }
        let next = (retained + active).sorted { $0.name < $1.name }
        if next != acceptedToolCatalog {
            acceptedToolCatalog = next
            toolCatalogRevision &+= 1
            saveToolCatalog()
        }
        reconciledRegistryRevision = registryRevision
        needsToolCatalogReconcile = false
        return next
    }

    public func toolBindingIdentity(_ realName: String) -> String? {
        cacheableTools().first(where: { $0.name == realName }).map { $0.owner + "|" + $0.name }
    }

    private func saveToolCatalog() {
        guard let data = try? JSONEncoder().encode(CachedToolCatalog(owners: configuredToolOwners, tools: acceptedToolCatalog)) else { return }
        try? FileManager.default.createDirectory(at: toolCatalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: toolCatalogURL, options: .atomic)
    }

    public init(catalog: PluginCatalog, settings: InMemorySettingsRegistry? = nil) {
        self.catalog = catalog
        self.tools = InMemoryToolRegistry()
        self.prompt = InMemoryPromptRegistry()
        self.slots = InMemorySlotRegistry()
        self.settings = settings ?? InMemorySettingsRegistry()
        self.events = InMemoryEventBus()
        self.imageAdapters = ProviderImageAdapterRegistry()
        self.hostData = HostDataRegistry()
        self.root = ServiceRealm(seed: [
            "tools": tools,
            "prompt": prompt,
            "slots": slots,
            "settings": self.settings,
            "events": events,
            "provider.imageAdapters": imageAdapters,
            "host.data": hostData,
        ])
        loadToolCatalog()
    }

    private func loadToolCatalog() {
        guard let data = try? Data(contentsOf: toolCatalogURL),
              let saved = try? JSONDecoder().decode(CachedToolCatalog.self, from: data) else { return }
        configuredToolOwners = saved.owners
        acceptedToolCatalog = saved.tools
    }

    public func provideService(_ name: String, _ value: Any) {
        root.provide(name, value)
    }

    public func unmountAll() {
        _ = cacheableTools()
        for context in contexts.values { context.dispose() }
        contexts.removeAll()
        fibers.removeAll()
        issues.removeAll()
        needsToolCatalogReconcile = true
    }

    @discardableResult
    public func mount(_ document: CompositionDocument) -> [MountIssue] {
        unmountAll()
        needsToolCatalogReconcile = true
        let previousOwners = configuredToolOwners
        let previousCatalog = acceptedToolCatalog
        mounting = true
        configuredToolOwners = Dictionary(document.entries.map { ($0.id, $0.plugin) }, uniquingKeysWith: { first, _ in first })
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
                let privateNames = Set(isolate.filter(\.value).keys)
                // Honored on both planes: isolated names never reach the shared root.
                let realm = privateNames.isEmpty ? root : ServiceRealm(parent: root, isolated: privateNames)
                for name in inject {
                    if realm.get(name) == nil {
                        throw PluginError.missingService(name)
                    }
                }
                let publishedBefore = Set(root.publishedNames)
                let context = LivePluginContext(
                    rowId: entry.id,
                    pluginId: resolved.manifest.id,
                    pluginDirectory: resolved.directory,
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
                // Register the context before apply so even a plugin that
                // registers a closure and then throws is fully disposed.
                contexts[entry.id] = context
                try FiberLocal.$owner.withValue(entry.id) {
                    try plugin.apply(context)
                }
                if document.plane == .session {
                    let published = Set(root.publishedNames).subtracting(publishedBefore)
                    if !published.isEmpty {
                        throw PluginError.globalService(published.sorted().joined(separator: ", "))
                    }
                }
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
            configuredToolOwners = previousOwners
            acceptedToolCatalog = previousCatalog
            needsToolCatalogReconcile = true
            mounting = false
            issues = nextIssues
            return nextIssues
        }
        mounting = false
        issues = []
        _ = cacheableTools()
        saveToolCatalog()
        events.emit("plugins/mounted", fibers.map(\.id))
        return []
    }
}
