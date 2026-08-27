// Copyright (c) 2026 DOTS
// Plugin catalog and support paths for Dots Harness.

import Foundation
import HarnessPluginKit

public enum PluginKind: String, Sendable {
    case builtin
    case manifest
    case dylib
}

public struct CatalogEntry: Identifiable, Sendable {
    public var id: String { manifest.id }
    public var manifest: PluginManifest
    public var kind: PluginKind
    public var trust: PluginTrust
    public var enabled: Bool
    public var broken: String?
    public var url: URL?

    public init(
        manifest: PluginManifest,
        kind: PluginKind,
        trust: PluginTrust,
        enabled: Bool = true,
        broken: String? = nil,
        url: URL? = nil
    ) {
        self.manifest = manifest
        self.kind = kind
        self.trust = trust
        self.enabled = enabled
        self.broken = broken
        self.url = url
    }
}

public struct ResolvedPlugin {
    public var manifest: PluginManifest
    public var kind: PluginKind
    public var trust: PluginTrust
    public var make: () throws -> HarnessPlugin
}

public struct SupportPaths: Sendable {
    public var root: URL
    public var plugins: URL
    public var presets: URL
    public var settings: URL
    public var hostPatch: URL
    public var trust: URL
    public var models: URL
    public var runtime: URL

    public init(
        root: URL,
        plugins: URL,
        presets: URL,
        settings: URL,
        hostPatch: URL,
        trust: URL,
        models: URL,
        runtime: URL
    ) {
        self.root = root
        self.plugins = plugins
        self.presets = presets
        self.settings = settings
        self.hostPatch = hostPatch
        self.trust = trust
        self.models = models
        self.runtime = runtime
    }

    public static func `default`(fileManager: FileManager = .default) -> SupportPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = base.appendingPathComponent("DotsHarness", isDirectory: true)
        return SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
    }

    public func ensure(fileManager: FileManager = .default) {
        try? fileManager.createDirectory(at: plugins, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: presets, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: models, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: runtime, withIntermediateDirectories: true)
    }
}

public final class PluginCatalog: ObservableObject {
    @Published public private(set) var entries: [CatalogEntry] = []

    public let paths: SupportPaths
    private var builtins: [String: () -> HarnessPlugin] = [:]
    private var builtinManifests: [String: PluginManifest] = [:]
    private var trustOverrides: [String: PluginTrust] = [:]
    private var disabled: Set<String> = []
    private var didLoadTrust = false

    public init(paths: SupportPaths = .default()) {
        self.paths = paths
    }

    public func registerBuiltin(_ plugin: HarnessPlugin.Type, refresh: Bool = true) {
        let manifest = plugin.manifest
        builtinManifests[manifest.id] = manifest
        builtins[manifest.id] = { plugin.initForCatalog() }
        if refresh {
            self.refresh()
        }
    }

    public func refresh() {
        paths.ensure()
        if !didLoadTrust {
            loadTrust()
            didLoadTrust = true
        }

        var next: [CatalogEntry] = []
        for (id, manifest) in builtinManifests.sorted(by: { $0.key < $1.key }) {
            next.append(CatalogEntry(
                manifest: manifest,
                kind: .builtin,
                trust: .system,
                enabled: !disabled.contains(id)
            ))
        }
        let fm = FileManager.default
        if let children = try? fm.contentsOfDirectory(at: paths.plugins, includingPropertiesForKeys: nil) {
            for folder in children where folder.hasDirectoryPath {
                let yaml = folder.appendingPathComponent("plugin.yml")
                guard fm.fileExists(atPath: yaml.path) else { continue }
                do {
                    let text = try String(contentsOf: yaml, encoding: .utf8)
                    let manifest = try MiniYAML.decode(PluginManifest.self, from: text)
                    let kind: PluginKind = manifest.library == nil ? .manifest : .dylib
                    let trust = trustOverrides[manifest.id] ?? .untrusted
                    next.append(CatalogEntry(
                        manifest: manifest,
                        kind: kind,
                        trust: trust,
                        enabled: !disabled.contains(manifest.id),
                        url: folder
                    ))
                } catch {
                    next.append(CatalogEntry(
                        manifest: PluginManifest(
                            id: folder.lastPathComponent,
                            name: folder.lastPathComponent,
                            version: "0.0.0",
                            plane: .session
                        ),
                        kind: .manifest,
                        trust: .untrusted,
                        enabled: false,
                        broken: error.localizedDescription,
                        url: folder
                    ))
                }
            }
        }
        entries = next
    }

    public func setTrust(_ id: String, _ trust: PluginTrust) {
        guard builtinManifests[id] == nil else { return }
        trustOverrides[id] = trust
        persistTrust()
        refresh()
    }

    public func setEnabled(_ id: String, _ isEnabled: Bool) {
        if isEnabled { disabled.remove(id) } else { disabled.insert(id) }
        persistTrust()
        refresh()
    }

    public func resolve(_ id: String) throws -> ResolvedPlugin {
        if let factory = builtins[id], let manifest = builtinManifests[id] {
            return ResolvedPlugin(manifest: manifest, kind: .builtin, trust: .system, make: factory)
        }
        guard let entry = entries.first(where: { $0.manifest.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        if let broken = entry.broken {
            throw PluginError.invalidManifest(broken)
        }
        switch entry.kind {
        case .builtin:
            throw PluginError.unknownPlugin(id)
        case .manifest:
            return ResolvedPlugin(manifest: entry.manifest, kind: .manifest, trust: entry.trust) {
                ManifestPlugin(manifest: entry.manifest, directory: entry.url)
            }
        case .dylib:
            guard let folder = entry.url, let library = entry.manifest.library else {
                throw PluginError.invalidManifest("missing library")
            }
            let url = folder.appendingPathComponent(library)
            return ResolvedPlugin(manifest: entry.manifest, kind: .dylib, trust: entry.trust) {
                try PluginDylib.load(from: url)
            }
        }
    }

    private func loadTrust() {
        guard let data = try? Data(contentsOf: paths.trust),
              let object = try? JSONDecoder().decode(TrustFile.self, from: data) else { return }
        trustOverrides = object.trust
        disabled = Set(object.disabled)
    }

    private func persistTrust() {
        let file = TrustFile(trust: trustOverrides, disabled: Array(disabled).sorted())
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: paths.trust, options: .atomic)
        }
    }
}

private struct TrustFile: Codable {
    var trust: [String: PluginTrust]
    var disabled: [String]
}

private extension HarnessPlugin {
    static func initForCatalog() -> HarnessPlugin {
        if let type = self as? any DefaultPlugin.Type {
            return type.create()
        }
        return ManifestPlugin(manifest: manifest, directory: nil)
    }
}
