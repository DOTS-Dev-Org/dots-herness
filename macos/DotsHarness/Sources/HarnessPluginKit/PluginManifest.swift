// Copyright (c) 2026 DOTS
// Plugin manifest model for Dots Harness.

import Foundation

public enum PluginPlane: String, Codable, Sendable, CaseIterable {
    case host
    case session
}

public enum PluginTrust: String, Codable, Sendable, CaseIterable {
    /// Shipped with the app. Always enabled for loading.
    case system
    /// User accepted network / dylib privileges.
    case trusted
    /// Prompt + local slots only.
    case untrusted
}

public struct PromptSectionSpec: Codable, Sendable, Equatable {
    public var name: String
    public var order: Int
    public var file: String?
    public var text: String?

    public init(name: String, order: Int, file: String? = nil, text: String? = nil) {
        self.name = name
        self.order = order
        self.file = file
        self.text = text
    }
}

public struct PluginManifest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var abi: String
    public var plane: PluginPlane
    public var inject: [String]
    public var description: String
    public var library: String?
    public var promptSection: PromptSectionSpec?

    public static let currentABI = "1.0.0"

    public init(
        id: String,
        name: String,
        version: String,
        abi: String = PluginManifest.currentABI,
        plane: PluginPlane,
        inject: [String] = [],
        description: String = "",
        library: String? = nil,
        promptSection: PromptSectionSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.abi = abi
        self.plane = plane
        self.inject = inject
        self.description = description
        self.library = library
        self.promptSection = promptSection
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, abi, plane, inject, description, library, promptSection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.1.0"
        abi = try container.decodeIfPresent(String.self, forKey: .abi) ?? PluginManifest.currentABI
        plane = try container.decodeIfPresent(PluginPlane.self, forKey: .plane) ?? .session
        inject = try container.decodeIfPresent([String].self, forKey: .inject) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        library = try container.decodeIfPresent(String.self, forKey: .library)
        promptSection = try container.decodeIfPresent(PromptSectionSpec.self, forKey: .promptSection)
    }

    public var abiCompatible: Bool {
        SemVer(abi)?.major == SemVer(PluginManifest.currentABI)?.major
    }
}

public struct SemVer: Sendable, Equatable, Comparable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init?(_ raw: String) {
        let parts = raw.split(separator: ".").map(String.init)
        guard parts.count >= 1, let major = Int(parts[0]) else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        self.patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct PluginIdentity: Hashable, Sendable {
    public var id: String
    public init(_ id: String) { self.id = id }
}
