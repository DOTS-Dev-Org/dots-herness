// Copyright (c) 2026 DOTS
// Resolves and injects directory-scoped project rules for workspace operations.

import Foundation

enum ProjectRulePromptContext {
    struct Scope: Sendable, Equatable {
        let relativePath: String
        let text: String

        private var identity: String {
            Data(relativePath.utf8).base64EncodedString()
        }

        var message: AgentMessage? {
            guard !text.isEmpty else { return nil }
            let section = PromptSection(
                tag: "project_scope_rules",
                trust: .rules,
                text: "Scope ID: \(identity)\nApplies to paths under: \(relativePath)\n\(text)"
            )
            return AgentMessage(
                role: .system,
                content: section.wrapped(defusing: ProjectRulePromptContext.sectionTags),
                systemKind: .promptDynamic
            )
        }

        var identityMarker: String { "Scope ID: \(identity)\n" }
    }

    fileprivate static let sectionTags: Set<String> = [
        "core_policy", "response_language", "runtime_context", "desktop_control", "current_date",
        "project_brief", "project_knowledge", "plan_mode", "economy_mode", "response_style",
        "self_verification", "workspace_activity", "project_context", "project_scope_rules",
        "user_memory", "learned_rules", "project_memory", "task_history", "area_lessons", "plugin_guidance",
    ]
    private static let maxActiveContextBytes = 48_000

    /// Resolves a built-in workspace tool's target to the scoped rules for that path.
    static func scope(for call: AgentToolCall, workspace: URL) -> Scope? {
        guard let data = call.arguments.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let path: String
        let isDirectory: Bool
        switch call.name {
        case "list_files":
            path = arguments["path"] as? String ?? "."
            isDirectory = true
        case "grep_files", FileEditTools.globName:
            path = arguments["path"] as? String ?? "."
            isDirectory = true
        case "read_file", "write_file", "remove_file", FileEditTools.editName:
            guard let value = arguments["path"] as? String else { return nil }
            path = value
            isDirectory = false
        case WorkspaceTools.generatedMediaName:
            guard let value = arguments["destination_path"] as? String else { return nil }
            path = value
            isDirectory = false
        default:
            return nil
        }

        guard let target = try? WorkspaceTools.resolve(path, workspace: workspace),
              let resolved = ProjectRules.scopedContext(
                workspace: workspace,
                target: target,
                targetIsDirectory: isDirectory
              ) else { return nil }
        return Scope(relativePath: resolved.relativePath, text: resolved.text)
    }

    static func isMutation(_ call: AgentToolCall) -> Bool {
        ["write_file", "remove_file", FileEditTools.editName, WorkspaceTools.generatedMediaName].contains(call.name)
    }

    /// True only if the current transcript does not already carry this exact,
    /// metadata-validated snapshot of the applicable rules.
    static func contains(_ scope: Scope, in messages: [AgentMessage]) -> Bool {
        let existing = messages.first {
            $0.role == .system && $0.systemKind == .promptDynamic && $0.content.contains(scope.identityMarker)
        }
        guard !scope.text.isEmpty else { return existing == nil }
        guard let expected = scope.message else { return false }
        return existing?.content == expected.content
    }

    /// Replaces a stale copy for the same directory or inserts the current rules
    /// beside the other system sections, before any user or tool messages.
    @discardableResult
    static func apply(_ scope: Scope, to messages: inout [AgentMessage]) -> Bool {
        if contains(scope, in: messages) { return false }

        if let index = messages.firstIndex(where: {
            $0.role == .system && $0.systemKind == .promptDynamic && $0.content.contains(scope.identityMarker)
        }) {
            messages.remove(at: index)
        }

        guard let message = scope.message else { return true }
        let insertionIndex = messages.firstIndex(where: { $0.role != .system }) ?? messages.endIndex
        messages.insert(message, at: insertionIndex)
        trimOldScopes(from: &messages)
        return true
    }

    private static func trimOldScopes(from messages: inout [AgentMessage]) {
        func scopedIndices() -> [Int] {
            messages.indices.filter {
                messages[$0].role == .system
                    && messages[$0].systemKind == .promptDynamic
                    && messages[$0].content.hasPrefix("<project_scope_rules trust=\"rules\">")
            }
        }

        var indices = scopedIndices()
        var total = indices.reduce(0) { $0 + messages[$1].content.utf8.count }
        while total > maxActiveContextBytes, let oldest = indices.first {
            total -= messages[oldest].content.utf8.count
            messages.remove(at: oldest)
            indices = scopedIndices()
        }
    }

    static func rootRulesMessage(workspace: URL) -> AgentMessage? {
        let text = ProjectRules.text(workspace: workspace)
        guard !text.isEmpty else { return nil }
        let section = PromptSection(
            tag: "project_context",
            trust: .rules,
            text: "Applies to all files in the workspace.\n\(text)"
        )
        return AgentMessage(
            role: .system,
            content: section.wrapped(defusing: sectionTags),
            systemKind: .promptDynamic
        )
    }
}
