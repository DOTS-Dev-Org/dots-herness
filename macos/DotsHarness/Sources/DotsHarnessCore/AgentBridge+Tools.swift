// Copyright (c) 2026 DOTS
// Tool definitions, system prompt, tool execution, approvals and vision fallback.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

@MainActor
final class PromptPreparationMetrics {
    private(set) var cpuStages: [String: Int] = [:]
    private(set) var cacheHits: [String: Int] = [:]
    private(set) var cacheMisses: [String: Int] = [:]

    func record(_ stage: String, since start: UInt64, to end: UInt64 = AgentStepCPUTrace.thread()) {
        cpuStages[stage, default: 0] += AgentStepCPUTrace.milliseconds(since: start, to: end)
    }

    func recordCache(_ name: String, hit: Bool) {
        if hit { cacheHits[name, default: 0] += 1 }
        else { cacheMisses[name, default: 0] += 1 }
    }

    func takeStages() -> [String: Int] {
        defer { cpuStages.removeAll(keepingCapacity: true) }
        return cpuStages
    }

    func takeCacheHits() -> [String: Int] {
        defer { cacheHits.removeAll(keepingCapacity: true) }
        return cacheHits
    }

    func takeCacheMisses() -> [String: Int] {
        defer { cacheMisses.removeAll(keepingCapacity: true) }
        return cacheMisses
    }
}

private struct AgentToolCatalogKey: Hashable {
    let hasWorkspace: Bool
    let subagentsEnabled: Bool
    let computerUseEnabled: Bool
    let pluginIdentity: ObjectIdentifier?
    let pluginRevision: UInt64
    let mcpIdentity: ObjectIdentifier?
    let mcpRevision: UInt64
}

@MainActor
private final class CachedAgentToolCatalog {
    weak var pluginHost: PluginHost?
    weak var mcpRegistry: MCPRegistry?
    let definitions: [AgentToolDefinition]
    let pluginNames: [String: String]

    init(
        pluginHost: PluginHost?,
        mcpRegistry: MCPRegistry?,
        definitions: [AgentToolDefinition],
        pluginNames: [String: String]
    ) {
        self.pluginHost = pluginHost
        self.mcpRegistry = mcpRegistry
        self.definitions = definitions
        self.pluginNames = pluginNames
    }

    func matches(pluginHost: PluginHost?, mcpRegistry: MCPRegistry?) -> Bool {
        self.pluginHost === pluginHost && self.mcpRegistry === mcpRegistry
    }
}

@MainActor
private enum AgentToolCatalogCache {
    private static var entries: [AgentToolCatalogKey: CachedAgentToolCatalog] = [:]
    private static var insertionOrder: [AgentToolCatalogKey] = []

    static func value(
        for key: AgentToolCatalogKey,
        pluginHost: PluginHost?,
        mcpRegistry: MCPRegistry?
    ) -> CachedAgentToolCatalog? {
        guard let value = entries[key], value.matches(pluginHost: pluginHost, mcpRegistry: mcpRegistry) else {
            entries[key] = nil
            insertionOrder.removeAll { $0 == key }
            return nil
        }
        return value
    }

    static func insert(_ value: CachedAgentToolCatalog, for key: AgentToolCatalogKey) {
        if entries[key] == nil { insertionOrder.append(key) }
        entries[key] = value
        while insertionOrder.count > 8 {
            entries.removeValue(forKey: insertionOrder.removeFirst())
        }
    }
}

private struct CorePolicySectionKey: Hashable {
    let hasWorkspace: Bool
    let subagentsEnabled: Bool
}

@MainActor
private enum CorePolicySectionCache {
    private(set) static var sections: [CorePolicySectionKey: PromptSection] = [:]

    static func value(for key: CorePolicySectionKey) -> PromptSection? { sections[key] }
    static func store(_ section: PromptSection, for key: CorePolicySectionKey) { sections[key] = section }
}

extension NativeAgentHost {
    var subagentsEnabled: Bool {
        AgentRunScope.subagentsOverride ?? (router?.subagentsEnabled == true)
    }

    /// Fast mode may use subagents for this prompt even when the persistent
    /// Settings preference is off. The prompt snapshots this value at submission.
    var subagentsEnabledForNewPrompt: Bool {
        let fastModeEnabled = router?.fastMode == true
            && router.map { $0.supportsFast($0.selectedModelID) } == true
        return router?.subagentsEnabled == true || fastModeEnabled
    }

    /// The catalog used to build provider tool requests. The plan-mode prompt lists
    /// only the deferred controls, not this full provider schema surface.
    func agentTools(workspace: URL?, metrics: PromptPreparationMetrics? = nil) -> (defs: [AgentToolDefinition], pluginNames: [String: String]) {
        // Reconcile plugin registrations only when their registry generation
        // changes, then reuse the composed provider catalog by its inputs.
        if let pluginHost {
            _ = pluginHost.cacheableTools()
            metrics?.recordCache("plugin_registry", hit: pluginHost.lastToolCatalogCacheHit)
        }
        let key = AgentToolCatalogKey(
            hasWorkspace: workspace != nil,
            subagentsEnabled: subagentsEnabled,
            computerUseEnabled: isComputerUseEnabled,
            pluginIdentity: pluginHost.map(ObjectIdentifier.init),
            pluginRevision: pluginHost?.toolCatalogRevision ?? 0,
            mcpIdentity: mcpRegistry.map(ObjectIdentifier.init),
            mcpRevision: mcpRegistry?.toolDefinitionsRevision ?? 0
        )
        if let cached = AgentToolCatalogCache.value(for: key, pluginHost: pluginHost, mcpRegistry: mcpRegistry) {
            metrics?.recordCache("tool_catalog", hit: true)
            if pluginHost != nil { metrics?.recordCache("plugin_definitions", hit: true) }
            if mcpRegistry != nil { metrics?.recordCache("mcp_definitions", hit: true) }
            return (cached.definitions, cached.pluginNames)
        }
        metrics?.recordCache("tool_catalog", hit: false)
        if pluginHost != nil { metrics?.recordCache("plugin_definitions", hit: false) }

        // The parent keeps its write tools: a small edit done here costs one call,
        // while a delegate re-reads the files and runs a whole extra loop.
        let workspaceTools: [AgentToolDefinition] = workspace == nil ? [] : WorkspaceTools.definitions
        let sandboxTools: [AgentToolDefinition] = workspace != nil
            ? [Self.sandboxStatusDefinition]
            : []
        // Withheld entirely when the user turned subagents off: no schema tokens,
        // and the prompt below drops its pointers to the tool from the same flag.
        let exploreTools: [AgentToolDefinition] = workspace != nil && subagentsEnabled
            ? [ExploreTool.definition, DelegateTool.definition]
            : []
        let pluginTools = pluginToolDefinitions()
        let mcpTools = mcpToolDefinitions()
        if let mcpRegistry {
            metrics?.recordCache("mcp_definitions", hit: mcpRegistry.lastToolDefinitionsCacheHit)
        }
        // Off by default, so it is not offered until the user enables it: no schema
        // tokens and no "unavailable" notice in every conversation. Toggling it
        // mid-conversation starts a new cache epoch (catalog_changed).
        let computerUseDefs = isComputerUseEnabled ? ComputerUseTools.definitions : []
        let defs = workspaceTools + sandboxTools + exploreTools + SkillTools.definitions + [AskUserTool.definition]
            + [RememberTool.definition, InstallPluginTool.definition]
            + WebTools.definitions
            + (workspace != nil ? [TerminalSessionTool.definition, RecallTool.definition] : [])
            + [PlanStepsTool.definition, Self.latestAttachmentDefinition]
            + BrowserTools.definitions
            + NativeBrowserTools.definitions
            + computerUseDefs
            + pluginTools.defs
            + mcpTools
        AgentToolCatalogCache.insert(
            CachedAgentToolCatalog(
                pluginHost: pluginHost,
                mcpRegistry: mcpRegistry,
                definitions: defs,
                pluginNames: pluginTools.nameMap
            ),
            for: key
        )
        return (defs, pluginTools.nameMap)
    }

    /// Tools plan mode withholds. They stay in every request's tool list, so
    /// toggling plan mode never rewrites the cached prefix; the run loop rejects
    /// them instead. The plan prompt keeps its tool list to the deferred controls.
    nonisolated static func planWithholds(_ name: String) -> Bool {
        risk(name) == .workspaceMutation
            || [RememberTool.name, InstallPluginTool.name, PlanStepsTool.name,
                NativeBrowserTools.toolName,
                ComputerUseTools.toolName].contains(name)
            || BrowserTools.names.contains(name)
    }

    func planToolNames(workspace: URL?) -> [String] {
        agentTools(workspace: workspace).defs.map(\.name).filter { !Self.planWithholds($0) }
    }

    static let sandboxStatusName = "sandbox_status"
    static let latestAttachmentName = "get_latest_attachment"
    private static let latestAttachmentDefinition = AgentToolDefinition(
        name: latestAttachmentName,
        description: "Read the latest immutable source revision for an attachment after a revision notice. This is read-only; call it only when the current bytes are needed.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "attachment_id": .object([
                    "type": .string("string"),
                    "description": .string("The stable attachment_id from the revision notice."),
                ]),
            ]),
            "required": .array([.string("attachment_id")]),
            "additionalProperties": .bool(false),
        ])
    )
    private static let sandboxStatusDefinition = AgentToolDefinition(
        name: sandboxStatusName,
        description: "Report whether the current workspace is running inside a HerNess sandbox and its process boundaries.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    func sandboxStatus() -> String {
        guard let sandboxPolicy else {
            return "Sandbox inactive. The current workspace is the user's checkout."
        }
        return """
        Sandbox active
        workspace: \(sandboxPolicy.workspaceURL.path)
        branch: \(sandboxBranch ?? "unknown")
        writes: workspace and temporary directories only
        network: \(sandboxPolicy.networkAccess ? "enabled for new processes" : "disabled for new processes")
        origin writes: unavailable to agent processes
        """
    }

    /// The stable prefix alone. Cache keys and telemetry hash only this, so they must not
    /// pay for the memory, git and file-index sections built beside it.
    func corePolicySection(workspace: URL?, metrics: PromptPreparationMetrics? = nil) -> PromptSection {
        let key = CorePolicySectionKey(hasWorkspace: workspace != nil, subagentsEnabled: subagentsEnabled)
        if let cached = CorePolicySectionCache.value(for: key) {
            metrics?.recordCache("core_policy", hit: true)
            return cached
        }
        metrics?.recordCache("core_policy", hit: false)
        let exploreGuidance = workspace != nil && subagentsEnabled ? """

        - Delegate a broad read-only sweep (many files, only the conclusion needed, such as a
          whole-repository review split by area) to explore, at most 2 calls per response.
          Read the files you will change yourself.
        - Make edits yourself. Use delegate only for two or more independent parts with
          non-overlapping files, or one large part across many files you have not read; you
          still review its changed lines and run the relevant check.
        """ : ""
        let platformGuidance = """

        Tool use on this platform
        - Search file contents with grep_files rather than a shell grep.\(exploreGuidance)
        - File tools load matching descendant AGENTS.md, CLAUDE.md and AGENTS.override.md as
          trust="rules" context for their path. More-specific directory rules override parent rules
          only within that subtree; AGENTS.override.md replaces same-directory AGENTS.md/CLAUDE.md.
          If a write is refused because new scope rules were loaded, review them and retry.
        - Before run_command or terminal_session work aimed at a subproject, call list_files for
          that directory so its scoped rules are in context.
        - After execution_plan, keep the visible step list current with update_plan as steps land.
        """
        let section = PromptSection(
            tag: "core_policy",
            trust: .core,
            text: HerNessPrompt.core(
                scope: "See <runtime_context> for the active workspace scope.",
                toolGuidance: "See <runtime_context> for the active tool boundary."
            ) + platformGuidance
        )
        CorePolicySectionCache.store(section, for: key)
        return section
    }

    /// The prompt broken into trust-tagged sections. `systemPrompt` joins these;
    /// `effectiveSystemPromptReport` renders them for the Settings view, so both
    /// always describe the same text.
    func systemPromptSections(
        workspace: URL?,
        planMode: Bool = false,
        prompt: String = "",
        metrics: PromptPreparationMetrics? = nil
    ) -> [PromptSection] {
        let guidanceStarted = AgentStepCPUTrace.thread()
        let scope = workspace.map { HerNessPrompt.workspaceScope($0.path) } ?? HerNessPrompt.noWorkspaceScope
        let toolGuidance = workspace == nil
            ? "No project is open, so local file and command tools are unavailable — select a project before claiming to inspect or modify files. web_search and web_fetch still work."
            : "Use the provided workspace, terminal, run, browser, web, plugin, and MCP tools for every file read, file write, and command. For anything outside the workspace — library documentation, an error message you do not recognise, a changelog — use web_search and web_fetch instead of answering from memory."
        let sandboxGuidance: String = sandboxPolicy.map { policy in
            """

            Sandbox execution
            - This run is inside the HerNess sandbox worktree \(policy.workspaceURL.path).
            - Sandbox branch: \(sandboxBranch ?? "unknown").
            - Agent writes are limited to this worktree and temporary directories; the origin checkout is unavailable.
            - Network access for new processes is \(policy.networkAccess ? "enabled" : "disabled").
            - Pushing and deploying (git push, scp, rsync, wrangler, publish) are unavailable here; the user does them after merging.
            - SwiftPM cannot nest its own sandbox here: pass --disable-sandbox to swift build, test, run and package.
            - Do not attempt to merge, discard, or write to the origin; only the user can approve those actions in Settings.
            """
        } ?? ""
        let remoteGuidance: String = remoteTarget.map { target in
            """

            Remote execution over SSH
            - This run works on the remote host \(target.alias), in \(target.remotePath).
            - run_command executes there through a non-interactive `/bin/sh -lc`. There is no
              TTY, so anything that prompts (`sudo` without NOPASSWD, an editor, a pager) fails
              instead of waiting; run those in the terminal panel yourself or avoid them.
            - The local machine's files are not visible: list_files, read_file, write_file,
              remove_file and grep_files are unavailable in this mode. Use shell commands
              (`ls`, `sed -n`, `grep -rn`, a heredoc write) through run_command instead.
            - MCP tools and plugin actions still run on the user's own machine, not on \(target.alias).
            """
        } ?? ""
        let searchGuidance = searchFolders.isEmpty ? "" : """

        Additional read-only search folders
        - The configured folders below are available only to list_files, read_file, and grep_files.
        - Keep all writes, deletes, and commands inside the current workspace.
        - Use absolute paths when searching an additional folder:
        \(searchFolders.map { "  - \($0.path)" }.joined(separator: "\n"))
        """
        let memoryGuidance = workspace == nil ? "" : """


        Durable memory
        - <user_memory>, <learned_rules> and <project_memory> are what you know about this user
          and project: work from them and never ask again for what they state. Their
          "architecture", "conventions" and "design-system" entries describe this codebase;
          verify changeable details against code, and interface work reuses the design system's
          colors, type and components.
        - Before finishing, record with remember each lasting preference the user stated and each
          lasting project decision or change your work made, with its reason; one fact per call,
          never a guess. When <task_history> lacks or hides findings for the request, use recall
          before searching the workspace.
        - A lesson opens with its id and source: "user" wins over "inferred". Name the id when a
          lesson decided how you worked.
        """
        // Asked only while the vault still holds no brief: the first answers end
        // the condition, so a project is asked once and never again.
        // ponytail: no "declined" marker - if the user answers nothing the ask
        // repeats; add one if that turns out to annoy anyone.
        let briefGuidance = (workspace == nil || memory.hasProjectBrief || planMode) ? "" : """


        Project brief
        - This workspace has no brief yet. Before starting real work on it, ask the user with
          ask_user, in one call: what this project is for, the hard constraints, and what is
          explicitly out of scope.
        - Record each answer with remember (kind "project", keys "goal", "constraints",
          "out-of-scope"), then carry out their request. Record only what the user said about
          the project as a whole: never the current task as its goal, and never that something
          was not stated - leave that key unrecorded instead.
        - Skip the brief for a one-off question, a trivial edit, or when the user has already
          told you these in this conversation - record what they said instead of asking again.
        """
        let knowledgeGuidance = (!isMemoryWorkspace(workspace) || planMode)
            ? ""
            : ProjectKnowledge.guidance(missing: memory.missingKnowledge)
        let query = retrievalQuery(prompt)
        let planGuidance = planMode
            ? HerNessPrompt.planMode(tools: DeferredToolSession.definitions.map(\.name))
            : ""
        let economyGuidance = router?.usageMode == .economy
            ? """

            Economy mode: keep prose as short as the answer allows and omit optional explanations and alternatives. Stop when the success criteria are met.
            """
            : ""
        let responseStyleGuidance = router?.responseStylePreference.decision.guidance ?? ""
        let runtimeGuidance = [
            "Active workspace and run boundaries",
            "- Scope: \(scope)",
            "- Tool boundary: \(toolGuidance)",
            memoryGuidance,
            sandboxGuidance,
            remoteGuidance,
            searchGuidance,
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n")
        metrics?.record("prompt_guidance", since: guidanceStarted)

        let activityStarted = AgentStepCPUTrace.thread()
        let activityText = workspaceActivityText(workspace: workspace)
        metrics?.record("prompt_activity", since: activityStarted)

        let rulesStarted = AgentStepCPUTrace.thread()
        let ruleSnapshot = ProjectRules.snapshot(workspace: workspace)
        metrics?.record("prompt_rules", since: rulesStarted)
        metrics?.recordCache("project_rules", hit: ruleSnapshot.cacheHit)

        let memoryStarted = AgentStepCPUTrace.thread()
        let userMemoryText = isMemoryWorkspace(workspace)
            ? memory.profile.text(
                projectID: memory.projectID,
                stack: memory.stack,
                // Untrusted repository memory hides no personal preference.
                projectKeys: memory.projectMemoryTrusted ? Set(memory.projectMemoryFacts().map { $0.key }) : []
            )
            : memory.enabled ? memory.profile.text() : ""
        let learnedRuleText = learnedRulesText(workspace: workspace)
        let projectMemoryText = isMemoryWorkspace(workspace) ? memory.projectText() : ""
        let taskHistoryText = isMemoryWorkspace(workspace)
            ? memory.historyText(for: query, lessons: feedbackStore?.lessons() ?? [])
            : workspaceURL?.standardizedFileURL == workspace?.standardizedFileURL
                ? memory.filesText(for: query, lessons: feedbackStore?.lessons() ?? [])
                : ""
        let areaLessonText = isMemoryWorkspace(workspace)
            ? feedbackStore?.areaLessonsText(for: PromptArea.areas(in: prompt)) ?? ""
            : ""
        metrics?.record("prompt_memory", since: memoryStarted)

        let sectionsStarted = AgentStepCPUTrace.thread()
        let sections = [
            corePolicySection(workspace: workspace, metrics: metrics),
            PromptSection(
                tag: "response_language",
                trust: .core,
                text: ResponseLanguage.detect(in: prompt)?.responseInstruction ?? ""
            ),
            PromptSection(tag: "runtime_context", trust: .core, text: runtimeGuidance),
            PromptSection(tag: "desktop_control", trust: .core, text: isComputerUseEnabled
                ? ComputerUseTools.guidance
                : "Computer Use is disabled: never claim to have seen or controlled a desktop app; say a UI change was not visually checked and can be after the user enables it in Settings."),
            // Each in a section of its own: the date moves every day and the brief
            // request ends once answered, and neither should re-capture the whole
            // run-boundary block above with it.
            PromptSection(
                tag: "current_date",
                trust: .core,
                text: "Current date: \(Date().formatted(.iso8601.year().month().day()))"
            ),
            PromptSection(tag: "project_brief", trust: .core, text: briefGuidance),
            PromptSection(tag: "project_knowledge", trust: .core, text: knowledgeGuidance),
            PromptSection(tag: "plan_mode", trust: .core, text: planGuidance),
            PromptSection(tag: "economy_mode", trust: .core, text: economyGuidance),
            PromptSection(tag: "response_style", trust: .core, text: responseStyleGuidance),
            PromptSection(
                tag: "self_verification",
                trust: .core,
                text: (selfVerification && workspace != nil && !planMode)
                    ? HerNessPrompt.selfVerification
                    : ""
            ),
            PromptSection(
                tag: "workspace_activity",
                trust: .data,
                text: activityText
            ),
            PromptSection(
                tag: "project_context",
                trust: .rules,
                text: ruleSnapshot.text
            ),
            // Memory is sections by owner as well as by change rate. The person's
            // (user_memory, learned_rules, task_history) live on this Mac; project_memory
            // comes from the repository. A turn captures only the sections whose text
            // changed, so what moves every turn must not drag the rest along.
            PromptSection(
                tag: "user_memory",
                trust: .rules,
                text: userMemoryText
            ),
            PromptSection(tag: "learned_rules", trust: .rules, text: learnedRuleText),
            PromptSection(
                tag: "project_memory",
                trust: memory.projectMemoryTrusted ? .data : .untrusted,
                text: projectMemoryText
            ),
            PromptSection(
                tag: "task_history",
                trust: .data,
                // The file index is not memory: it is built here from git's index and kept
                // nowhere, so it still answers with memory switched off.
                text: taskHistoryText
            ),
            PromptSection(
                tag: "area_lessons",
                trust: .rules,
                text: areaLessonText
            ),
            PromptSection(tag: "plugin_guidance", trust: .untrusted, text: additionalSystemPrompt),
        ]
        metrics?.record("prompt_sections", since: sectionsStarted)
        return sections
    }

    /// Files another conversation in this workspace touched recently, plus files that
    /// changed during this conversation's own turns without it writing them.
    /// Read once per run: the session store is small and this keeps the agent
    /// from blaming a concurrent edit on its own change.
    func workspaceActivityText(workspace: URL?) -> String {
        guard let workspace else { return "" }
        let mine = activeConversationID ?? selectedID
        let cutoff = Date().addingTimeInterval(-30 * 60)
        var lines: [String] = []
        let conversationIDs = store.loadHeaders(workspacePath: workspace.path)
            .filter { $0.id != mine }
            .map(\.id)
        store.forEachRecentChangedFiles(ids: conversationIDs, since: cutoff) { _, title, changedFiles in
            var paths: [String] = []
            var seenPaths = Set<String>()
            for file in changedFiles where seenPaths.insert(file.path).inserted {
                paths.append(file.path)
            }
            guard !paths.isEmpty else { return }
            lines.append("- conversation \"\(title)\": \(paths.joined(separator: ", "))")
        }
        var text = ""
        if !lines.isEmpty {
            text += "Changed in the last 30 minutes by another conversation in this workspace:\n"
                + lines.joined(separator: "\n") + "\n"
        }
        if !concurrentChanges.isEmpty {
            text += "Changed during your own turns although you never wrote them, so an editor "
                + "or another conversation did:\n"
                + concurrentChanges.map { "- \($0.path) (\($0.operation.rawValue))" }.joined(separator: "\n")
                + "\n"
        }
        return text
    }

    /// Lessons tied to a file reach the model when it opens or changes that file,
    /// appended to the tool result - once per conversation. They are not in the
    /// prompt: most turns never touch the file, and there they would cost every
    /// turn instead of the one that needs them.
    func fileLessonNotice(for call: AgentToolCall, conversationID: String) -> String {
        guard ["read_file", "write_file", FileEditTools.editName].contains(call.name),
              let feedbackStore,
              let path = Self.argument(call, key: "path"), !path.isEmpty else { return "" }
        let fresh = feedbackStore.lessons(forPath: path)
            .filter { deliveredFileLessons[conversationID]?.contains($0.id) != true }
        guard !fresh.isEmpty else { return "" }
        deliveredFileLessons[conversationID, default: []].formUnion(fresh.map(\.id))
        return "\n\nLearned earlier about this file (apply it; an unconfirmed one is only a hint to verify):\n" + fresh.map { "- " + $0.cited }.joined(separator: "\n")
    }

    /// What memory is searched with. A request like "arayüzü düzelt" shares no
    /// word with a task titled "Restyle the settings screen", so the words of its
    /// area are added in both languages; and one too short to say what it is
    /// about ("şunu düzelt") borrows the last turns and the files they changed.
    /// ponytail: a fixed word table and a two-word threshold - replace with
    /// embeddings if the table keeps missing what users actually type.
    func retrievalQuery(_ prompt: String) -> String {
        var parts = [prompt] + PromptArea.areas(in: prompt).sorted { $0.rawValue < $1.rawValue }
            .map { $0.keywords.joined(separator: " ") }
        if FeedbackStore.tokens(prompt).count < 3,
           let conversation = conversations.first(where: { $0.id == (activeConversationID ?? selectedID) }) {
            for message in conversation.messages.suffix(6) {
                if message.kind == .user { parts.append(String(message.text.prefix(500))) }
                parts += message.changedFiles.map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent }
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Notes which records this turn's prompt carries, so the vault can show
    /// what is actually used and how often turns still get corrected.
    func logInjectedMemory(
        prompt: String,
        workspace: URL?,
        conversationID: String,
        turnID: String?,
        runID: String,
        provider: String,
        model: String
    ) {
        guard isMemoryWorkspace(workspace), let feedbackStore else { return }
        feedbackStore.logTurn(
            records: feedbackStore.injectedRecords(areas: PromptArea.areas(in: prompt))
                + memory.projectDefaults.keys.sorted().map { WorkspaceMemory.projectNotePrefix + $0 },
            conversationID: conversationID,
            turnID: turnID,
            runID: runID,
            provider: provider,
            model: model
        )
    }

    // MARK: - Editing memory from the vault

    public var lessons: [Lesson] { Lesson.ranked(feedbackStore?.lessons() ?? []) }
    public var manualRules: String { feedbackStore?.manualRules() ?? "" }

    /// Every edit goes through here: what a person types into memory is sent to
    /// a model and committed with the repository, so a credential is refused.
    /// Returns false when nothing was saved.
    @discardableResult
    public func editMemory(_ edit: MemoryEdit) -> Bool {
        let text: String
        switch edit {
        case .setProject(_, let value), .editLesson(_, let value), .setManualRules(let value), .addManualRule(let value),
             .setPreference(_, let value, _), .addInsight(_, let value), .editInsight(_, let value):
            text = value
        case .forgetProject, .pinLesson, .forgetLesson, .deletePreference, .deleteTask, .deleteConversation, .deleteInsight: text = ""
        }
        // What a person types is sent to the model, and project entries are committed.
        guard !RememberTool.looksLikeSecret(.init(kind: "project", key: "note", text: text)) else { return false }
        do {
            switch edit {
            case .setProject(let key, let value):
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? try memory.forgetProjectDefault(key: key)
                    : try memory.setProjectDefault(key: key, value: value)
            case .forgetProject(let key): try memory.forgetProjectDefault(key: key)
            case .pinLesson(let id): try feedbackStore?.pinLesson(id: id)
            case .forgetLesson(let id): try feedbackStore?.forgetLesson(id: id)
            case .editLesson(let id, let rule): try feedbackStore?.editLesson(id: id, rule: rule)
            case .setManualRules(let rules): try feedbackStore?.setManualRules(rules)
            case .addManualRule(let rule):
                let line = "- " + rule.trimmingCharacters(in: .whitespacesAndNewlines)
                let current = feedbackStore?.manualRules() ?? ""
                try feedbackStore?.setManualRules(current.isEmpty ? line : current + "\n" + line)
            case .setPreference(let key, let value, .everywhere): try memory.setUserPreference(key: key, value: value)
            case .setPreference(let key, let value, .thisProject): try memory.setProjectUserPreference(key: key, value: value)
            case .deletePreference(let key, let scope): try memory.removeUserPreference(key: key, scope: scope)
            case .deleteTask(let runID): try memory.deleteTaskNote(runID: runID)
            case .deleteConversation(let noteID): try memory.deleteConversationNote(noteID: noteID)
            case .deleteInsight(let id): memory.deleteInsight(id: id)
            case .addInsight(let kind, let text): memory.writeInsight(id: nil, kind: kind, text: text)
            case .editInsight(let id, let text): memory.writeInsight(id: id, kind: nil, text: text)
            }
        } catch {
            return false
        }
        if let feedbackStore { shareLessons(from: feedbackStore) }
        return true
    }

    /// The feedback store follows the project's id, which exists once memory has been
    /// opened for the workspace. Called when the workspace opens and after the first
    /// prompt, which is when that id is created.
    func syncFeedbackStore() {
        let directory = memory.userMemoryDirectory
        guard feedbackStore?.directory != directory else { return }
        feedbackStore = directory.map { FeedbackStore(directory: $0) }
    }

    /// Opens the project's memory so feedback has a folder to live in. It is the one
    /// path besides a prompt that creates the project id, and it is taken only when the
    /// person actually gives feedback.
    @discardableResult
    func openProjectMemory() -> Bool {
        do { try memory.openProject() } catch { return false }
        syncFeedbackStore()
        return feedbackStore != nil
    }

    public var learningStats: (turns: Int, corrected: Int, uses: [(record: String, count: Int)]) {
        feedbackStore?.learningStats() ?? (0, 0, [])
    }

    private func isMemoryWorkspace(_ workspace: URL?) -> Bool {
        guard memory.enabled, let workspace else { return false }
        return workspaceURL?.standardizedFileURL == workspace.standardizedFileURL
    }

    /// What the user taught HerNess in this project: their recorded preferences
    /// and the rules derived from their feedback.
    private func learnedRulesText(workspace: URL?) -> String {
        guard isMemoryWorkspace(workspace) else { return "" }
        let preferences = memory.preferencesText()
        return [
            preferences.isEmpty ? "" : "## The user's preferences in this project\n\(preferences)",
            feedbackStore?.rulesText() ?? "",
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Only invariant policy belongs ahead of history. Runtime boundaries,
    /// dates, modes and project data are captured once on each new user turn.
    func systemPromptMessages(
        workspace: URL?,
        planMode: Bool,
        prompt: String,
        metrics: PromptPreparationMetrics? = nil
    ) -> [AgentMessage] {
        let sections = systemPromptSections(workspace: workspace, planMode: planMode, prompt: prompt, metrics: metrics)
        let stable = sections.filter { $0.tag == "core_policy" }
        let dynamic = sections.filter { $0.tag != "core_policy" }
        let knownTags = HerNessPrompt.sectionTags(sections)
        let assemblyStarted = AgentStepCPUTrace.thread()
        var messages: [AgentMessage] = []
        let stableText = HerNessPrompt.assemble(stable, knownTags: knownTags)
        if !stableText.isEmpty {
            messages.append(AgentMessage(
                role: .system,
                content: stableText,
                systemKind: .promptStable
            ))
        }
        let dynamicText = HerNessPrompt.assemble(dynamic, knownTags: knownTags)
        if !dynamicText.isEmpty {
            messages.append(AgentMessage(
                role: .system,
                content: dynamicText,
                systemKind: .promptDynamic
            ))
        }
        metrics?.record("prompt_assembly", since: assemblyStarted)
        return messages
    }

    /// What Settings shows: the real assembled prompt, section by section, with
    /// sizes and credential-looking values masked.
    public func effectiveSystemPromptReport(planMode: Bool = false) -> String {
        let prompt = selected.map(conversationPrompt) ?? ""
        let report = HerNessPrompt.report(
            systemPromptSections(workspace: workspaceURL, planMode: planMode, prompt: prompt)
        )
        let churn = NativeAgentClient.promptSectionChurnReport(in: selected?.modelContext ?? [])
        return [report, churn].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Single source of truth for each tool's base risk. Read-only device
    /// inventory actions are exempted directly in `requiresApproval`.
    /// Plugin (`plugin__*`) and MCP (`mcp__*`) tools default to `.sideEffect`
    /// unless their registry declares otherwise; those registries are consulted
    /// by the callers that own them, this covers the built-in set and the
    /// conservative fallback.
    nonisolated static func risk(_ toolName: String) -> ToolRisk {
        if toolName.hasPrefix("skill.") || DeferredToolSession.definitions.contains(where: { $0.name == toolName }) { return .readOnly }
        switch toolName {
        case "write_file", "remove_file", FileEditTools.editName, WorkspaceTools.generatedMediaName,
             DelegateTool.name:
            return .workspaceMutation
        case "list_files", "read_file", "grep_files", FileEditTools.globName,
             WebTools.fetchName, WebTools.searchName,
             ExploreTool.name, AskUserTool.name, PlanStepsTool.name, RememberTool.name, RecallTool.name,
             sandboxStatusName, latestAttachmentName,
             WorkspaceTools.generatedMediaInspectionName, WorkspaceTools.waitName:
            return .readOnly
        default:
            // run_command, ios_simulator, terminal_session, plugin__*, mcp__* …
            return .sideEffect
        }
    }

    nonisolated static func requiresApproval(
        mode: AgentPermissionMode,
        toolName: String,
        action: String? = nil
    ) -> Bool {
        if toolName.hasPrefix("skill.") { return false }
        if toolName == "ios_simulator", action == "list_devices" { return false }
        if toolName == AndroidEmulatorTools.toolName,
           (action == "list_devices" || action == "list_avds") { return false }
        switch mode {
        case .ask:
            return true
        case .safe:
            return risk(toolName) != .readOnly
        case .full:
            return false
        }
    }

    // MARK: - Plugin tools

    /// Tools registered by mounted plugins, exposed to the model under a
    /// `plugin__` prefix so their names can't collide with the built-ins.
    /// Returns the definitions plus a map from the exposed name back to the real
    /// registry name for dispatch.
    func pluginToolDefinitions() -> (defs: [AgentToolDefinition], nameMap: [String: String]) {
        guard let registered = pluginHost?.cacheableTools(), !registered.isEmpty else { return ([], [:]) }
        var defs: [AgentToolDefinition] = []
        var nameMap: [String: String] = [:]
        let groups = Dictionary(grouping: registered, by: { "plugin__" + Self.sanitizeToolName($0.name) })
        for tool in registered.sorted(by: { $0.name < $1.name }) {
            let exposed = "plugin__" + Self.sanitizeToolName(tool.name)
            // Ambiguous sanitized names must never bind according to discovery order.
            guard groups[exposed]?.count == 1 else { continue }
            nameMap[exposed] = tool.name
            defs.append(AgentToolDefinition(
                name: exposed,
                description: tool.description,
                parameters: Self.jsonSchema(for: tool.parameters)
            ))
        }
        return (defs, nameMap)
    }

    /// MCP server tools, exposed under an `mcp__<server>__<tool>` prefix.
    func mcpToolDefinitions() -> [AgentToolDefinition] {
        mcpRegistry?.toolDefinitions() ?? []
    }

    func runPluginTool(_ realName: String, call: AgentToolCall) async -> String {
        guard let host = pluginHost else { return AppCopy.format("tool.invalidArguments", call.name) }
        do {
            return try await host.tools.call(realName, arguments: Self.stringArguments(call.arguments))
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    func materializeMedia(_ payloads: [MediaPayload]) async -> [ChatMedia] {
        guard !payloads.isEmpty else { return [] }
        let store = paths
        // Materialising one artifact — copying it in from the provider's transient
        // location — does not depend on the next, so a multi-image reply no longer
        // waits through them one by one. Order and per-item failure reporting stay.
        let settled: [(media: ChatMedia?, error: String?)] = await withTaskGroup(
            of: (Int, ChatMedia?, String?).self
        ) { group in
            for (index, payload) in payloads.enumerated() {
                group.addTask {
                    do {
                        return (index, try await MediaGenerationClient.materialize(payload, paths: store), nil)
                    } catch {
                        return (index, nil, error.localizedDescription)
                    }
                }
            }
            var results: [(media: ChatMedia?, error: String?)] = Array(
                repeating: (nil, nil), count: payloads.count
            )
            for await (index, media, error) in group { results[index] = (media, error) }
            return results
        }
        var media: [ChatMedia] = []
        for result in settled {
            if let item = result.media {
                media.append(item)
            } else if let error = result.error {
                status = error
            }
        }
        return media
    }

    // MARK: - Agent terminal sessions

    public func stopAllAgentTerminals() {
        for session in agentTerminals.values.flatMap({ $0 }) {
            session.onExit = nil
            session.stop()
        }
        agentTerminals.removeAll()
    }

    public func stopAgentTerminals(for workspacePath: String) {
        let path = SandboxProfile.canonicalURL(URL(fileURLWithPath: workspacePath, isDirectory: true)).path
        for key in Array(agentTerminals.keys) {
            let sessions = agentTerminals[key] ?? []
            let remaining = sessions.filter { session in
                guard session.workspacePath == path else { return true }
                session.onExit = nil
                session.stop()
                return false
            }
            agentTerminals[key] = remaining.isEmpty ? nil : remaining
        }
    }

    /// Wakes the conversation that started a background task: the notice joins its
    /// prompt queue, so it starts a turn when idle and follows the running one otherwise.
    /// A task the user stopped has no exit code and only releases the messages it held back.
    func backgroundTaskFinished(_ session: TerminalSession, in conversationID: String) {
        guard agentTerminals[conversationID]?.contains(where: { $0 === session }) == true else { return }
        // Re-publish, so the task list regroups the session under finished.
        agentTerminals[conversationID] = agentTerminals[conversationID]
        if let code = session.exitCode {
            let outcome = code == 0
                ? AppCopy.text("tasks.notification.completed")
                : AppCopy.format("backgroundTasks.failed", Int(code))
            queueNotice(
                AppCopy.format("backgroundTasks.wake", session.title, Int(code), session.id.uuidString),
                shownAs: "\(session.title) · \(outcome)",
                in: conversationID
            )
        }
        // A turn the user stopped stays stopped: the notice waits for Continue or "send now".
        guard !state(for: conversationID).queuePausedAfterStop else { return }
        startQueuedPromptIfReleased(in: conversationID)
    }

    /// Ahead of the messages that waited for the task: the agent picks its own work up first.
    private func queueNotice(_ text: String, shownAs notice: String, in conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let pending = conversations[index].pendingPrompts
        conversations[index].pendingPrompts.insert(
            PendingPrompt(text: text, mode: .queue, notice: notice),
            at: pending.firstIndex(where: { $0.notice == nil }) ?? pending.endIndex
        )
        persist()
    }

    /// How long a background task must stay silent on an unfinished line to count as asking.
    static var backgroundInputQuiet: TimeInterval = 8

    /// Fallback for a remote shell, where a read cannot be seen exactly: silence on an
    /// unfinished line is what a prompt looks like.
    // ponytail: a guess, so a quiet step that printed "Building... " wakes the agent once
    // for nothing; local tasks never take this path.
    func watchForInput(_ session: TerminalSession, in conversationID: String) {
        Task { @MainActor [weak self, weak session] in
            var reported: Date?
            while let self, let session, session.isRunning {
                try? await Task.sleep(for: .seconds(min(2, Self.backgroundInputQuiet / 2)))
                guard session.isRunning,
                      session.lastOutputAt != reported,
                      Date().timeIntervalSince(session.lastOutputAt) >= Self.backgroundInputQuiet,
                      let last = session.output.last, !last.isNewline,
                      self.agentTerminals[conversationID]?.contains(where: { $0 === session }) == true else { continue }
                reported = session.lastOutputAt
                self.backgroundTaskNeedsInput(session, in: conversationID, certain: false)
            }
        }
    }

    /// Wakes the agent for a background task that wants input, so the question is answered
    /// or passed to the user instead of hanging unseen.
    func backgroundTaskNeedsInput(_ session: TerminalSession, in conversationID: String, certain: Bool = true) {
        guard agentTerminals[conversationID]?.contains(where: { $0 === session }) == true else { return }
        queueNotice(
            """
            Background task "\(session.title)" (session \(session.id.uuidString)) \
            \(certain ? "is waiting for input" : "has gone quiet and looks like it is waiting for input"). \
            Its last output:
            \(session.output.suffix(600))

            \(certain ? "" : "If this is not a prompt, end your turn; you will be told when the task exits. ")\
            If it is a routine confirmation the user's request already covers, answer it with \
            terminal_session send. Otherwise ask the user and send their answer; do not guess. \
            Never ask for a password or other secret in chat: stop the task and tell the user \
            to run the command in their own terminal.
            """,
            shownAs: "\(session.title) · \(AppCopy.text("backgroundTasks.waitingInput"))",
            in: conversationID
        )
        guard !state(for: conversationID).queuePausedAfterStop else { return }
        startQueuedPromptIfReleased(in: conversationID)
    }

    func clearFinishedAgentTerminals(in conversationID: String) {
        let running = (agentTerminals[conversationID] ?? []).filter(\.isRunning)
        agentTerminals[conversationID] = running.isEmpty ? nil : running
    }

    func agentTerminal(
        _ call: AgentToolCall,
        conversationID: String,
        workspace: URL?
    ) -> String {
        let action = Self.argument(call, key: "action") ?? ""
        var sessions = agentTerminals[conversationID] ?? []

        let userSessions = userTerminalManager?.sessions(for: remoteTarget?.identity ?? workspace?.path ?? "") ?? []

        func find() -> TerminalSession? {
            let id = Self.argument(call, key: "session_id") ?? ""
            return sessions.first { $0.id.uuidString == id }
        }
        func snapshot(_ session: TerminalSession) -> String {
            let limit = Int(Self.argument(call, key: "max_chars") ?? "") ?? 4000
            let tail = String(session.output.suffix(max(200, limit)))
            let selection = session.selectedText.isEmpty
                ? ""
                : "\n--- selected by the user ---\n\(session.selectedText.suffix(max(200, limit)))"
            let state = session.isRunning ? "running" : "exited\(session.exitCode.map { " \($0)" } ?? "")"
            return "session \(session.id.uuidString) [\(state)]\n\(tail)\(selection)"
        }

        switch action {
        case "list":
            guard !sessions.isEmpty || !userSessions.isEmpty else { return "No agent terminal sessions." }
            return (sessions.map { "\($0.id.uuidString) [\($0.isRunning ? "running" : "exited")] \($0.title)" }
                + userSessions.map {
                    "\($0.id.uuidString) [user's dock terminal, read-only\($0.selectedText.isEmpty ? "" : ", has a selection")]"
                }).joined(separator: "\n")

        case "start":
            let session: TerminalSession
            if let remote = remoteTarget {
                session = TerminalSession(remoteTarget: remote)
            } else if let workspace {
                session = TerminalSession(
                    workspacePath: workspace.path,
                    sandboxPolicy: sandboxPolicy?.agentCommandPolicy()
                )
            } else {
                return "Tool error: select a project workspace before starting a terminal session."
            }
            let command = Self.argument(call, key: "command") ?? ""
            // Local tasks run under the job-control loop, which reports reads exactly.
            let exactInput = !command.isEmpty && remoteTarget == nil
            if exactInput {
                session.launchEnvironment = [
                    TerminalSession.taskEnvironmentKey: TerminalSession.taskLoop,
                    TerminalSession.taskCommandKey: command,
                ]
            }
            session.start()
            guard session.isRunning else { return "Tool error: \(session.output)" }
            sessions.append(session)
            agentTerminals[conversationID] = sessions
            guard !command.isEmpty else {
                return "Started session \(session.id.uuidString). Use read to see output."
            }
            session.title = Self.argument(call, key: "description") ?? command
            session.onExit = { [weak self] session in
                self?.backgroundTaskFinished(session, in: conversationID)
            }
            session.onInputRequested = { [weak self] session in
                self?.backgroundTaskNeedsInput(session, in: conversationID)
            }
            // The shell leaves with the command's status; that exit is what ends the task.
            // Remote shells are not known to be zsh, so they get one plain eval line: the shell
            // has read all of it before the command runs, so nothing can swallow the exit.
            session.sendInput(exactInput
                ? TerminalSession.taskLauncher + "\n"
                : "eval \(SSHRunner.shellQuote(command)); exit $?\n")
            if !exactInput { watchForInput(session, in: conversationID) }
            return "Started background task \(session.id.uuidString). You will get a message when it exits or waits for input; do not poll."

        case "read":
            let id = Self.argument(call, key: "session_id") ?? ""
            guard let session = find() ?? userSessions.first(where: { $0.id.uuidString == id }) else {
                return "Tool error: unknown session_id."
            }
            return snapshot(session)

        case "send":
            guard let session = find() else { return "Tool error: unknown session_id." }
            guard session.isRunning else { return "Tool error: session has exited." }
            var input = Self.argument(call, key: "input") ?? ""
            if !input.hasSuffix("\n") { input += "\n" }
            session.sendInput(input)
            return "Sent. Call read to see the result."

        case "stop":
            guard let session = find() else { return "Tool error: unknown session_id." }
            session.stop()
            sessions.removeAll { $0.id == session.id }
            agentTerminals[conversationID] = sessions.isEmpty ? nil : sessions
            return "Stopped session \(session.id.uuidString)."

        default:
            return "Tool error: unknown action '\(action)'."
        }
    }

    func runMCPTool(_ exposedName: String, call: AgentToolCall, registry: MCPRegistry) async -> String {
        let arguments = (try? JSONCodec.parse(Data(call.arguments.utf8))) ?? .object([:])
        do {
            return try await registry.call(exposedName, arguments: arguments)
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    nonisolated static func sanitizeToolName(_ name: String) -> String {
        let cleaned = name.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "_" || ch == "-" ? ch : "_"
        }
        return String(cleaned)
    }

    nonisolated static func jsonSchema(for params: [ToolParameter]) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for param in params {
            properties[param.name] = .object([
                "type": .string(param.type.isEmpty ? "string" : param.type),
                "description": .string(param.description),
            ])
            if param.required { required.append(.string(param.name)) }
        }
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty { object["required"] = .array(required) }
        return .object(object)
    }

    /// Flattens a tool-call argument JSON object to the `[String: String]` shape
    /// the plugin and MCP registries expect. Nested values are re-serialized.
    nonisolated static func stringArguments(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                result[key] = string
            } else if value is [Any] || value is [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let string = String(data: data, encoding: .utf8) {
                result[key] = string
            } else if let bool = value as? Bool {
                result[key] = bool ? "true" : "false"
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    func applyVisionFallback(
        conversationID: String,
        messages: [AgentMessage],
        configuration: AgentConfiguration,
        providerError: NativeAgentError
    ) async throws -> [AgentMessage] {
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else {
            throw providerError
        }
        let userMessage = messages[userIndex]
        var seenImages = Set<String>()
        let images = messages
            .flatMap(\.attachments)
            .filter { $0.kind == .image && seenImages.insert($0.path).inserted }
            .map { VisionImageInput(filePath: $0.path, name: $0.name, mimeType: $0.mimeType) }
        guard !images.isEmpty else { throw providerError }
        let generatedInspectionPaths = Set(
            messages
                .filter { $0.role == .tool && $0.content.hasPrefix("[Generated media inspection]") }
                .flatMap(\.attachments)
                .filter { $0.kind == .image }
                .map(\.path)
        )
        let generatedInspectionOnly = !generatedInspectionPaths.isEmpty
            && images.allSatisfy { generatedInspectionPaths.contains($0.filePath) }
        /// A generated image nobody can read stays an asset instead of failing the turn.
        func inspectionNote() -> [AgentMessage] {
            let updated = Self.generatedMediaInspectionNote(messages, userIndex: userIndex, paths: generatedInspectionPaths)
            saveModelContext(updated, in: conversationID)
            return updated
        }

        var service = pluginHost?.getService(
            VisionFallbackDefaults.serviceName,
            as: VisionFallbackService.self
        )
        if service == nil || service?.state == .modelMissing || service?.state == .failed || service?.state == .unavailable {
            if generatedInspectionOnly { return inspectionNote() }
            let allow = await requestVisionInstall(
                conversationID: conversationID,
                provider: configuration.provider,
                model: configuration.model,
                modelBytes: service?.modelBytes ?? VisionFallbackDefaults.modelBytes,
                reason: AppCopy.text("vision.installPrompt")
            )
            guard allow else {
                if generatedInspectionOnly { return inspectionNote() }
                throw NativeAgentError(AppCopy.text("vision.notEnabled"))
            }
            if service == nil, let installer = pluginHost?.getService(
                VisionFallbackDefaults.installerServiceName,
                as: VisionFallbackInstaller.self
            ) {
                service = try await installer.install()
            }
        }

        guard let service else {
            if generatedInspectionOnly { return inspectionNote() }
            throw NativeAgentError(AppCopy.text("vision.pluginMissing"))
        }
        if service.state != .ready {
            do {
                try await service.prepare(progress: nil)
            } catch {
                if generatedInspectionOnly, !Task.isCancelled { return inspectionNote() }
                throw error
            }
        }
        let visualContext: String
        do {
            visualContext = try await service.describe(
                images: images,
                instruction: "Describe only observable visual facts in the attached image. Do not guess. "
                    + "Return a concise description that another language model can use to answer the user's request. "
                    + userMessage.content
            )
        } catch {
            if generatedInspectionOnly, !Task.isCancelled { return inspectionNote() }
            throw error
        }
        guard !visualContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if generatedInspectionOnly { return inspectionNote() }
            throw NativeAgentError(AppCopy.text("vision.emptyDescription"))
        }

        var updated = messages
        for index in updated.indices { updated[index].attachments = [] }
        updated[userIndex].content = Self.localVisionContext(userMessage.content, visualContext)
        saveModelContext(updated, in: conversationID)
        return updated
    }

    private static func generatedMediaInspectionNote(
        _ messages: [AgentMessage],
        userIndex: Int,
        paths: Set<String>
    ) -> [AgentMessage] {
        var updated = messages
        for index in updated.indices {
            updated[index].attachments.removeAll { paths.contains($0.path) }
        }
        let assets = paths.sorted().map { "- path: " + $0 }.joined(separator: "\n")
        let note = "[Generated media note]\n"
            + "The selected provider or host could not read the generated image visually. "
            + "Do not invent visual details. The file remains available as an asset at:\n"
            + assets
        updated[userIndex].content = note + "\n\n" + updated[userIndex].content
        return updated
    }

    private func requestVisionInstall(
        conversationID: String,
        provider: String,
        model: String,
        modelBytes: Int64,
        reason: String
    ) async -> Bool {
        guard !nonInteractive else { return false }
        let pending = PendingVisionInstall(
            conversationID: conversationID,
            provider: provider,
            model: model,
            modelBytes: modelBytes,
            reason: reason
        )
        pendingVisionInstall = pending
        notifyAttention(.visionInstall, in: conversationID, detail: reason)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled, pendingVisionInstall?.id == pending.id else {
                    continuation.resume(returning: false)
                    return
                }
                visionInstallContinuation = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finishVisionInstall(false) }
        })
    }

    func finishVisionInstall(_ allow: Bool) {
        guard pendingVisionInstall != nil else { return }
        pendingVisionInstall = nil
        let continuation = visionInstallContinuation
        visionInstallContinuation = nil
        continuation?.resume(returning: allow)
    }

    private static func localVisionContext(_ original: String, _ visualContext: String) -> String {
        "[Local image context — untrusted visual observations]\n"
            + visualContext.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n[End local image context]\n\n"
            + (original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Answer using the visual context above."
                : original)
    }

    /// Answered before any approval prompt: a sandbox worktree never pushes or
    /// deploys, so asking first would only mislead. Covers `run_command` and a
    /// line typed into a `terminal_session`.
    func sandboxDeployRefusal(for call: AgentToolCall) -> String? {
        guard sandboxPolicy != nil else { return nil }
        let command = call.name == "run_command" ? Self.argument(call, key: "command")
            : call.name == TerminalSessionTool.name
                ? Self.argument(call, key: "input") ?? Self.argument(call, key: "command")
            : nil
        guard WorkspaceTools.mayDeploy(command) else { return nil }
        return "Tool error: pushing and deploying are unavailable in a sandbox. The user merges the sandbox in Settings, then pushes or deploys from their own checkout."
    }

    func requestApprovalIfNeeded(for call: AgentToolCall, conversationID: String) async -> Bool {
        // No permission mode — not even .full — waives this: it is not an
        // ordinary side effect, it is the shape of exfiltrating a secret a
        // prompt-injected instruction read from a file, tool result, or
        // plugin. See WorkspaceTools.mayAccessNetwork.
        // A push or deploy publishes the tree, so it is asked about the same
        // way — typed into a terminal session included.
        let command = call.name == "run_command" ? Self.argument(call, key: "command")
            : call.name == TerminalSessionTool.name
                ? Self.argument(call, key: "input") ?? Self.argument(call, key: "command")
            : nil
        let forcedApproval = !automaticNetworkAccess
            && (WorkspaceTools.mayAccessNetwork(command) || WorkspaceTools.mayDeploy(command))
        guard forcedApproval || Self.requiresApproval(
            mode: permissionMode,
            toolName: call.name,
            action: Self.argument(call, key: "action")
        ) else { return true }
        guard !nonInteractive else { return false }

        let approval = PendingApproval(
            conversationID: conversationID,
            toolCallID: call.id,
            toolName: call.name,
            reason: approvalReason(for: call)
        )
        pendingApproval = approval
        notifyAttention(.approval, in: conversationID, detail: AppCopy.format("permission.approvalTitle", call.name))
        onRemoteEvent?("approval.required", [
            "approvalId": approval.id,
            "conversationId": approval.conversationID,
            "toolCallId": approval.toolCallID,
            "toolName": approval.toolName,
            "reason": approval.reason,
        ])

        let allowed = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled, pendingApproval?.id == approval.id else {
                    continuation.resume(returning: false)
                    return
                }
                approvalContinuation = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finishApproval(false) }
        })
        onRemoteEvent?("approval.resolved", [
            "approvalId": approval.id,
            "allowed": allowed ? "true" : "false",
        ])
        return allowed
    }

    /// Writes one durable fact to the layer it belongs to. Memory is an audit
    /// layer: a write failure is reported to the model, never to the run.
    func remember(_ call: AgentToolCall) -> String {
        guard let entry = RememberTool.parse(call.arguments) else { return RememberTool.malformedNotice }
        guard !RememberTool.looksLikeSecret(entry) else { return RememberTool.secretNotice }
        guard memory.enabled else { return RememberTool.unavailableNotice }
        do {
            switch entry.kind {
            case RememberTool.Kind.preference.rawValue where entry.scope == RememberTool.userScope:
                try memory.setUserPreference(key: entry.key, value: entry.text)
            case RememberTool.Kind.preference.rawValue:
                try memory.setProjectUserPreference(key: entry.key, value: entry.text)
            case RememberTool.Kind.project.rawValue:
                try memory.setProjectDefault(key: entry.key, value: entry.text)
            default:
                try memory.recordProjectDecision(summary: entry.text)
            }
        } catch {
            return RememberTool.unavailableNotice
        }
        memoryRevision += 1
        return RememberTool.confirmation(entry)
    }

    /// Searches this project's findings. Another workspace's run gets nothing: the open
    /// memory is this project's, and its findings must not reach another project's prompt.
    func recall(_ call: AgentToolCall, workspace: URL?) -> String {
        guard let query = RecallTool.query(call.arguments) else { return RecallTool.malformedNotice }
        guard isMemoryWorkspace(workspace) else { return RecallTool.unavailableNotice }
        let found = memory.recallText(query: query)
        return found.isEmpty ? RecallTool.emptyNotice : "Memory matching \"\(query)\". Trust the code over it when the two disagree.\n\(found)"
    }

    /// Writes an agent-authored plugin folder under the support plugins directory
    /// and asks the app to re-mount. Always installed untrusted; compiled (dylib)
    /// plugins are refused — the agent can only ship js/manifest/declarative.
    func installPlugin(_ call: AgentToolCall) -> String {
        let outcome = InstallPluginTool.write(call.arguments, into: paths.plugins)
        if outcome.installed { onPluginsChanged?() }
        return outcome.notice
    }

    func askUser(_ call: AgentToolCall, conversationID: String) async -> String {
        guard askUserRounds < AskUserTool.maxRounds else { return AskUserTool.repeatNotice }
        guard !nonInteractive else { return AskUserTool.unavailableNotice }
        let parsed = AskUserTool.parse(call.arguments)
        guard !parsed.isEmpty else { return AskUserTool.emptyNotice }
        // Follow-ups may only carry questions the user has not answered yet.
        let questions = parsed.filter { !askedQuestionKeys.contains(AskUserTool.fingerprint($0.prompt)) }
        guard !questions.isEmpty else { return AskUserTool.duplicateNotice }

        askUserRounds += 1
        askedQuestionKeys.formUnion(questions.map { AskUserTool.fingerprint($0.prompt) })
        let answers = await presentQuestions(questions, id: call.id, conversationID: conversationID)
        guard let answers, answers.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return AskUserTool.unavailableNotice
        }
        return AskUserTool.transcript(questions: questions, answers: answers)
    }

    /// Shows the question card and waits for the user. Nil when the run stops first.
    func presentQuestions(_ questions: [AskUserQuestion], id: String, conversationID: String) async -> [String]? {
        let pending = PendingQuestion(conversationID: conversationID, toolCallID: id, questions: questions)
        pendingQuestion = pending
        notifyAttention(.question, in: conversationID, detail: questions.map(\.prompt).joined(separator: " · "))
        onRemoteEvent?("question.required", [
            "questionId": pending.id,
            "conversationId": pending.conversationID,
            "count": String(questions.count),
        ])

        let answers = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
                guard !Task.isCancelled, pendingQuestion?.id == pending.id else {
                    continuation.resume(returning: nil)
                    return
                }
                questionContinuation = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finishQuestion(nil) }
        })
        onRemoteEvent?("question.resolved", ["questionId": pending.id])
        return answers
    }

    /// Before a turn, the host asks what only the user can settle about memory:
    /// whether memory that came with the repository is trusted, and whether a lesson
    /// inferred from a single turn is right. Nothing is assumed: an unanswered question
    /// leaves the memory untrusted and the lesson a hint. True when the prompt must be rebuilt.
    func askMemoryQuestions(conversationID: String, workspace: URL?) async -> Bool {
        guard !nonInteractive, isMemoryWorkspace(workspace) else { return false }
        var questions: [AskUserQuestion] = []
        let trustOptions = [AppCopy.text("memory.trust.yes"), AppCopy.text("memory.trust.no")]
        if memory.needsProjectMemoryTrust {
            questions.append(AskUserQuestion(
                id: "memory-trust",
                header: AppCopy.text("memory.trust.header"),
                prompt: AppCopy.text("memory.trust.prompt"),
                options: trustOptions
            ))
        }
        let lessonOptions = [AppCopy.text("memory.lesson.keep"), AppCopy.text("memory.lesson.forget")]
        // ponytail: three lessons a turn, newest first; the rest wait for the next turn.
        let lessons = (feedbackStore?.lessons() ?? [])
            .filter { !$0.isConfirmed && $0.isActive() && $0.reviewPromptDismissed != true && !askedLessonIDs.contains($0.id) }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(3)
        for lesson in lessons {
            askedLessonIDs.insert(lesson.id)
            try? feedbackStore?.dismissLessonPrompt(id: lesson.id)
            questions.append(AskUserQuestion(
                id: "lesson-" + lesson.id,
                header: AppCopy.text("memory.lesson.header"),
                prompt: AppCopy.format("memory.lesson.prompt", lesson.line),
                options: lessonOptions
            ))
        }
        guard !questions.isEmpty else { return false }
        let answers = await presentQuestions(questions, id: "memory-" + UUID().uuidString, conversationID: conversationID)
        // Skipping the trust question is an answer too: the memory stays untrusted (the
        // default) and the checkout is not asked again. A cancelled run decided nothing.
        if answers.map({ !trustOptions.contains($0.first ?? "") }) ?? true, !Task.isCancelled,
           questions.first?.id == "memory-trust" {
            try? memory.setProjectMemoryTrust(false)
        }
        guard let answers else {
            // Every review is marked when offered, so stopping here won't ask again.
            return false
        }
        var changed = false
        for (question, answer) in zip(questions, answers) {
            if question.id == "memory-trust", trustOptions.contains(answer) {
                try? memory.setProjectMemoryTrust(answer == trustOptions[0])
                changed = true
            } else if question.id.hasPrefix("lesson-") {
                let id = String(question.id.dropFirst("lesson-".count))
                if answer == lessonOptions[0] {
                    try? feedbackStore?.pinLesson(id: id)
                    changed = true
                } else if answer == lessonOptions[1] {
                    try? feedbackStore?.forgetLesson(id: id)
                    changed = true
                }
            }
        }
        if changed, let feedbackStore { shareLessons(from: feedbackStore) }
        return changed
    }

    func finishQuestion(_ answers: [String]?) {
        guard pendingQuestion != nil else { return }
        pendingQuestion = nil
        let continuation = questionContinuation
        questionContinuation = nil
        continuation?.resume(returning: answers)
    }

    func finishApproval(_ allowed: Bool) {
        guard pendingApproval != nil else { return }
        pendingApproval = nil
        let continuation = approvalContinuation
        approvalContinuation = nil
        continuation?.resume(returning: allowed)
    }

    private func approvalReason(for call: AgentToolCall) -> String {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppCopy.format("permission.toolReason", call.name)
        }

        switch call.name {
        case "write_file":
            return AppCopy.format("permission.writeReason", object["path"] as? String ?? ".")
        case WorkspaceTools.generatedMediaName:
            return "Allow this generated image to be copied into the workspace at \(object["destination_path"] as? String ?? "the requested path")?"
        case "run_command":
            let command = object["command"] as? String ?? ""
            return AppCopy.format("permission.commandReason", String(command.prefix(240)))
        case TerminalSessionTool.name where object["command"] is String || object["input"] is String:
            let command = object["command"] as? String ?? object["input"] as? String ?? ""
            return AppCopy.format("permission.commandReason", String(command.prefix(240)))
        case "ios_simulator", AndroidEmulatorTools.toolName:
            return AppCopy.text("permission.simulatorReason")
        case _ where BrowserTools.names.contains(call.name):
            return "Allow this run to control its owned browser page?"
        case ComputerUseTools.toolName:
            let action = object["action"] as? String ?? "action"
            return "Allow this run to perform desktop Computer Use (\(action))?"
        default:
            return AppCopy.format("permission.toolReason", call.name)
        }
    }
}
