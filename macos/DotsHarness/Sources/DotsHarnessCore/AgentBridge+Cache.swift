// Copyright (c) 2026 DOTS
import Foundation
import HarnessPluginKit

extension NativeAgentHost {
    func cacheBindingIDs(tools: [AgentToolDefinition], pluginNames: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: tools.map { tool in
            (tool.name, pluginNames[tool.name].flatMap { pluginHost?.toolBindingIdentity($0) } ?? mcpRegistry?.bindingIdentity(tool.name) ?? tool.name)
        })
    }

    func cacheBindings(tools: [AgentToolDefinition], pluginNames: [String: String]) -> String {
        let entries = cacheBindingIDs(tools: tools, pluginNames: pluginNames).map { $0.key + "=" + $0.value }.sorted()
        return AgentCacheTrace.fingerprint(entries.joined(separator: "\n"))
    }

    func prepareCacheEpoch(conversationID: String, tools: [AgentToolDefinition], pluginNames: [String: String],
                           messages: [AgentMessage]) -> [AgentToolDefinition] {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return tools }
        let bindings = cacheBindings(tools: tools, pluginNames: pluginNames)
        let policy = AgentCacheTrace.fingerprint(messages.filter {
            $0.role == .system && $0.systemKind != .promptDynamic
        }.map(\.content).joined(separator: "\n"))
        var epoch = conversations[index].cacheEpoch ?? .init(tools: tools, bindingsFingerprint: bindings,
            policyFingerprint: policy, contextSegment: conversations[index].contextCompactionCount)
        epoch.reconcile(tools: tools, bindings: bindings, policy: policy, segment: conversations[index].contextCompactionCount)
        conversations[index].cacheEpoch = epoch
        return epoch.tools.map(\.definition)
    }

    /// Called only between complete provider/tool groups. Source observations
    /// append facts; they never replace an already delivered user message.
    func appendCacheNotices(messages: inout [AgentMessage], conversationID: String,
                            attachments: [ChatAttachment], tools: [AgentToolDefinition], planMode: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              var epoch = conversations[index].cacheEpoch else { return }
        for attachment in attachments.sorted(by: { Self.attachmentKey($0) < Self.attachmentKey($1) }) {
            let observation = attachment.observeSource()
            let key = "attachment|" + Self.attachmentKey(attachment)
            let fingerprint = AgentCacheTrace.fingerprint([observation.status.rawValue,
                observation.currentHash ?? "", attachment.deliveredHash ?? "", String(attachment.revision)].joined(separator: "|"))
            let previous = epoch.noticeFingerprints[key]
            let text: String?
            if observation.status == .current {
                text = previous == nil ? nil : "[Attachment source status]\nattachment_id: \(attachment.id)\nstatus: current\nThe source is available again. Historical bytes remain unchanged."
            } else {
                text = Self.attachmentRevisionNotice(for: [attachment])
            }
            epoch.appendNotice(key: key, fingerprint: fingerprint, text: text, to: &messages)
        }
        let unavailable = tools.map(\.name).filter { !cacheToolAvailable($0) }.sorted()
        let availability = unavailable.joined(separator: "\n")
        let previousAvailability = epoch.noticeFingerprints["availability"]
        epoch.appendNotice(key: "availability", fingerprint: AgentCacheTrace.fingerprint(availability),
            text: unavailable.isEmpty && previousAvailability == nil ? nil :
                "[Tool availability]\nUnavailable tools: \(unavailable.isEmpty ? "none" : unavailable.joined(separator: ", ")). Current permissions are enforced when a tool is called.", to: &messages)
        // Mode guidance is dynamic input, rather than a changing tool catalog.
        // Existing prompt capture already carries the first turn's mode.
        let mode = planMode ? "plan" : "execute"
        let previousMode = epoch.noticeFingerprints["mode"]
        epoch.appendNotice(key: "mode", fingerprint: mode,
            text: previousMode == nil ? nil : planMode
                ? "[Mode change]\nPlan mode is active. Produce a plan and respect the tools withheld by plan mode."
                : "[Mode change]\nExecution mode is active. Follow the user's current instructions and normal tool permissions.", to: &messages)
        conversations[index].cacheEpoch = epoch
    }

    func cacheToolAvailable(_ name: String) -> Bool {
        if name == ComputerUseTools.toolName { return isComputerUseEnabled }
        if name.hasPrefix("mcp__") { return mcpRegistry?.isAvailable(name) == true }
        if name.hasPrefix("plugin__") {
            guard let real = pluginToolDefinitions().nameMap[name] else { return false }
            return pluginHost?.tools.tools().contains(where: { $0.name == real }) == true
        }
        return true
    }

    func cacheToolContractMatches(_ name: String, tools: [AgentToolDefinition], workspace: URL?, pluginNames: [String: String], bindings: [String: String]) -> Bool {
        guard cacheToolAvailable(name), let advertised = tools.first(where: { $0.name == name }) else { return false }
        let current = agentTools(workspace: workspace)
        guard let live = current.defs.first(where: { $0.name == name }), live == advertised else { return false }
        return current.pluginNames[name] == pluginNames[name]
            && cacheBindingIDs(tools: current.defs, pluginNames: current.pluginNames)[name] == bindings[name]
    }
}
