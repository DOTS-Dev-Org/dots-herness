// Copyright (c) 2026 DOTS
// Standalone plugin composition model for Dots Harness.

import Foundation

public struct CompositionEntry: Codable, Sendable, Equatable {
    public var id: String
    public var plugin: String
    public var disabled: Bool
    public var isolate: [String: Bool]
    public var config: JSONObject

    public init(
        id: String,
        plugin: String,
        disabled: Bool = false,
        isolate: [String: Bool] = [:],
        config: JSONObject = [:]
    ) {
        self.id = id
        self.plugin = plugin
        self.disabled = disabled
        self.isolate = isolate
        self.config = config
    }

    enum CodingKeys: String, CodingKey {
        case id, plugin, disabled, isolate, config
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        plugin = try container.decode(String.self, forKey: .plugin)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        isolate = try container.decodeIfPresent([String: Bool].self, forKey: .isolate) ?? [:]
        config = try container.decodeIfPresent(JSONObject.self, forKey: .config) ?? [:]
    }
}

public struct CompositionDocument: Codable, Sendable, Equatable {
    public var plane: PluginPlane
    public var entries: [CompositionEntry]

    public init(plane: PluginPlane, entries: [CompositionEntry]) {
        self.plane = plane
        self.entries = entries
    }
}

public enum CompositionPatch: Sendable, Equatable {
    case insert([CompositionEntry])
    case disable(String)
    case enable(String)
    case mergeConfig(id: String, config: JSONObject)

    public static func apply(_ patches: [CompositionPatch], to document: CompositionDocument) -> CompositionDocument {
        var entries = document.entries
        for patch in patches {
            switch patch {
            case .insert(let incoming):
                for entry in incoming {
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index] = entry
                    } else {
                        entries.append(entry)
                    }
                }
            case .disable(let id):
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].disabled = true
                }
            case .enable(let id):
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].disabled = false
                }
            case .mergeConfig(let id, let config):
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].config.merge(from: config)
                }
            }
        }
        return CompositionDocument(plane: document.plane, entries: entries)
    }
}

public struct MountIssue: Sendable, Equatable, Identifiable {
    public var id: String { rowId + ":" + message }
    public var rowId: String
    public var message: String

    public init(rowId: String, message: String) {
        self.rowId = rowId
        self.message = message
    }
}

public enum PluginError: Error, Sendable, Equatable, LocalizedError {
    case missingService(String)
    case unknownPlugin(String)
    case incompatibleABI(String)
    case untrustedLibrary(String)
    case applyFailed(String)
    case globalService(String)
    case slotCollision(String)
    case invalidManifest(String)
    case invalidComposition(String)
    case package(String)

    public var errorDescription: String? {
        switch self {
        case .missingService(let name): return "waiting for \(name)"
        case .unknownPlugin(let id): return "Cannot find plugin \(id)"
        case .incompatibleABI(let abi): return "incompatible ABI \(abi)"
        case .untrustedLibrary(let id): return "untrusted dylib \(id)"
        case .applyFailed(let message): return message
        case .globalService(let name): return "row published process-global service [\(name)]; a session service must sit behind an isolate realm or move to the host composition"
        case .slotCollision(let message): return message
        case .invalidManifest(let message): return message
        case .invalidComposition(let message): return message
        case .package(let message): return message
        }
    }
}
