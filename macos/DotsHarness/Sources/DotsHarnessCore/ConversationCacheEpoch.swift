// Copyright (c) 2026 DOTS
import Foundation
import HarnessPluginKit

/// Durable definitions contain no executable closures. Availability is always
/// checked against the current registry before invoking a snapshotted tool.
public struct AgentCachedToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    init(_ tool: AgentToolDefinition) {
        name = tool.name; description = tool.description; parameters = tool.parameters
    }
    var definition: AgentToolDefinition {
        .init(name: name, description: description, parameters: parameters)
    }
}

public struct AgentConversationCacheEpoch: Codable, Sendable, Equatable {
    public var id: String
    public var transformationVersion: Int
    public var catalogFingerprint: String
    public var bindingsFingerprint: String
    public var policyFingerprint: String
    public var contextSegment: Int
    public var tools: [AgentCachedToolDefinition]
    public var priorBoundary: AgentPromptCacheBoundary?
    public var noticeFingerprints: [String: String]
    public var lastChangeReason: String?

    init(tools: [AgentToolDefinition], bindingsFingerprint: String,
         policyFingerprint: String, contextSegment: Int) {
        id = UUID().uuidString
        transformationVersion = 2
        self.tools = tools.sorted { $0.name < $1.name }.map(AgentCachedToolDefinition.init)
        catalogFingerprint = AgentCacheNamespace.toolFingerprint(tools)
        self.bindingsFingerprint = bindingsFingerprint
        self.policyFingerprint = policyFingerprint
        self.contextSegment = contextSegment
        noticeFingerprints = [:]
    }

    /// Object-key/discovery order alone never rotates the epoch.
    mutating func reconcile(tools: [AgentToolDefinition], bindings: String, policy: String, segment: Int) {
        let catalog = AgentCacheNamespace.toolFingerprint(tools)
        let reason: String?
        if transformationVersion != 2 { reason = "transformation_changed" }
        else if catalogFingerprint != catalog || bindingsFingerprint != bindings { reason = "catalog_changed" }
        else if policyFingerprint != policy { reason = "policy_changed" }
        else if contextSegment != segment { reason = "context_compacted" }
        else { reason = nil }
        guard let reason else { return }
        id = UUID().uuidString
        transformationVersion = 2
        self.tools = tools.sorted { $0.name < $1.name }.map(AgentCachedToolDefinition.init)
        catalogFingerprint = catalog
        bindingsFingerprint = bindings
        policyFingerprint = policy
        contextSegment = segment
        priorBoundary = nil
        lastChangeReason = reason
    }

    /// A notice is an immutable appended message, never a rewrite of an old turn.
    mutating func appendNotice(key: String, fingerprint: String, text: String?, to messages: inout [AgentMessage]) {
        guard noticeFingerprints[key] != fingerprint else { return }
        noticeFingerprints[key] = fingerprint
        guard let text, !text.isEmpty else { return }
        var notice = AgentMessage(role: .user, content: text)
        notice.promptContextCaptured = true
        messages.append(notice)
    }
}
