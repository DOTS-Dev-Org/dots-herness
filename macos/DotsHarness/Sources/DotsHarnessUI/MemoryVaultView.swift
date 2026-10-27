// Copyright (c) 2026 DOTS
// Obsidian-style browser for workspace memory: searchable note list, rendered note
// with clickable [[wikilinks]], backlinks, and a zoomable force-directed link graph.
// Each note says which layer it comes from. Project notes (the repository) can only be
// taken out of the prompt, because the signed log keeps them; the person's own notes
// (this Mac) are deleted for good.

import AppKit
import SwiftUI
import DotsHarnessCore

public struct MemoryVaultView: View {
    let bridge: AgentBridge
    @State private var selectedID: String?
    /// The vault is read from disk when the view appears, on Refresh and after an
    /// edit - not on every redraw, which a selection causes.
    @State private var vault = MemoryVault()
    @State private var loaded = false
    @State private var refreshTick = 0
    @State private var search = ""
    @State private var newEntry: NewEntry?
    @State private var pendingDelete: MemoryEdit?
    /// Text being edited, and the note or lesson it belongs to.
    @State private var draft = ""
    @State private var draftID: String?
    @State private var lessonDraft = ""
    @State private var editingLesson: String?
    @State private var refused = false
    @State private var chatShown = true
    @State private var chat: [MemoryChatTurn] = []
    @State private var chatDraft = ""
    @State private var chatBusy = false
    /// The folder the shown chat was read from, so another project's chat replaces it.
    @State private var chatFolder: URL?
    /// The graph shows this project's own notes unless the person asks for every project.
    @State private var graphShowsAll = false

    public init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        Group {
            if !bridge.memoryReady || (loaded && vault.notes.isEmpty) {
                ContentUnavailableView(
                    AppCopy.text("memory.vault.title"),
                    systemImage: "brain",
                    description: Text(AppCopy.text("memory.notInitialized"))
                )
            } else if loaded {
                content(vault)
            } else {
                // An empty Group has no view to carry .task, so the vault would never load.
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // What the background work learns appears without pressing Refresh.
        .onChange(of: bridge.memoryChangeCount) { refreshTick += 1 }
        .task(id: refreshTick) {
            vault = bridge.memoryVault
            loaded = true
            if chatFolder != bridge.userMemoryFolderURL, !chatBusy {
                chatFolder = bridge.userMemoryFolderURL
                chat = bridge.memoryChatHistory
            }
        }
        .navigationTitle(AppCopy.text("settings.tab.memory"))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button(AppCopy.text("vault.new.projectEntry")) { newEntry = .project }
                    Button(AppCopy.text("vault.new.preference")) { newEntry = .preference }
                    Button(AppCopy.text("vault.new.rule")) { newEntry = .rule }
                } label: {
                    Label(AppCopy.text("vault.new"), systemImage: "plus")
                }
                .disabled(!bridge.memoryReady)
                Toggle(isOn: $chatShown) {
                    Label(AppCopy.text("vault.ask"), systemImage: "bubble.left.and.text.bubble.right")
                }
                .help(AppCopy.text("vault.ask.toggle"))
                Button(AppCopy.text("memory.refresh")) { refreshTick += 1 }
                if bridge.memoryFolderURL != nil {
                    Button(AppCopy.text("memory.reveal")) {
                        if let url = bridge.memoryFolderURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                if let url = bridge.userMemoryFolderURL {
                    Button(AppCopy.text("vault.folderOnMac")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .sheet(item: $newEntry) { kind in
            NewEntrySheet(bridge: bridge, kind: kind) { refreshTick += 1 }
        }
        .alert(
            AppCopy.text("vault.delete.confirm"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(AppCopy.text("archive.deletePermanently"), role: .destructive) {
                if let edit = pendingDelete {
                    save(edit)
                    selectedID = nil
                }
                pendingDelete = nil
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(AppCopy.text("vault.delete.message"))
        }
    }

    /// Fixed list column, not HSplitView/VSplitView: an NSSplitView reports the sum
    /// of its panes' minimum widths, and one long note title (~770pt) pushed the
    /// Settings content past the window edge and the sidebar off-screen.
    private func content(_ vault: MemoryVault) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                GraphView(
                    vault: graphShowsAll ? vault : Self.focused(vault),
                    selectedID: $selectedID,
                    matches: matches(in: vault),
                    showsAll: $graphShowsAll
                )
                    .frame(minHeight: 180, idealHeight: 240)
                Divider()
                HStack(spacing: 0) {
                    noteList(vault)
                        .frame(width: 240)
                    Divider()
                    noteDetail(vault)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if chatShown {
                Divider()
                chatPanel
                    .frame(width: 320)
            }
        }
    }

    /// This project's own notes: other projects, the technologies only they use and the
    /// files findings name are left to the list, so the graph shows what a prompt is built from.
    static func focused(_ vault: MemoryVault) -> MemoryVault {
        let notes = vault.notes.filter { note in
            !(note.kind == "file" || note.kind == "missing"
              || note.tags.contains(WorkspaceMemory.otherProjectTag)
              || (note.kind == "technology" && note.layer == .user))
        }
        let kept = Set(notes.map(\.id))
        return MemoryVault(notes: notes, edges: vault.edges.filter { kept.contains($0.from) && kept.contains($0.to) })
    }

    /// The notes the search field matches; nil while it is empty.
    private func matches(in vault: MemoryVault) -> Set<String>? {
        let needle = search.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !needle.isEmpty else { return nil }
        return Set(vault.notes.filter { note in
            (note.title + "\n" + note.body + "\n" + note.tags.joined(separator: " "))
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .contains(needle)
        }.map(\.id))
    }

    // MARK: - Memory chat

    private var chatPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if chat.isEmpty {
                            Text(AppCopy.text("vault.chat.empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        } else {
                            Button(AppCopy.text("vault.chat.clear")) {
                                chat = []
                                bridge.saveMemoryChat([])
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(chatBusy)
                        }
                        ForEach(chat) { turn in
                            chatTurn(turn).id(turn.id)
                        }
                        if chatBusy {
                            ProgressView().controlSize(.small).id("busy")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: chat.count) { _, _ in
                    withAnimation { proxy.scrollTo(chat.last?.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(AppCopy.text("vault.chat.placeholder"), text: $chatDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit(sendChat)
                Button(action: sendChat) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSendChat ? Color.accentColor : Color.secondary)
                .disabled(!canSendChat)
                .accessibilityLabel(AppCopy.text("feedback.submit"))
            }
            .padding(10)
        }
    }

    private var canSendChat: Bool {
        !chatBusy && !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func chatTurn(_ turn: MemoryChatTurn) -> some View {
        if turn.role == .user {
            Text(turn.text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                rendered(turn.text).textSelection(.enabled)
                ForEach(turn.applied, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(turn.deletions) { deletion in
                    HStack {
                        Button(deletion.title) { selectedID = deletion.id }
                            .buttonStyle(.link)
                            .lineLimit(1)
                        Spacer()
                        Button(AppCopy.text("common.delete"), role: .destructive) {
                            pendingDelete = deletion.edit
                            dropProposal(deletion.id, from: turn.id)
                        }
                        .controlSize(.small)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func dropProposal(_ noteID: String, from turnID: UUID) {
        guard let index = chat.firstIndex(where: { $0.id == turnID }) else { return }
        chat[index].deletions.removeAll { $0.id == noteID }
    }

    private func sendChat() {
        guard canSendChat else { return }
        chat.append(MemoryChatTurn(role: .user, text: chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)))
        chatDraft = ""
        chatBusy = true
        let history = chat
        Task {
            let answer = await bridge.memoryChat(history)
            chat.append(answer)
            chatBusy = false
            if chatFolder == bridge.userMemoryFolderURL { bridge.saveMemoryChat(chat) }
            if !answer.applied.isEmpty { refreshTick += 1 }
        }
    }

    // MARK: - Note list

    private func noteList(_ vault: MemoryVault) -> some View {
        let needle = search.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let shown = needle.isEmpty ? vault.notes : vault.notes.filter { note in
            (note.title + "\n" + note.body + "\n" + note.tags.joined(separator: " "))
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .contains(needle)
        }
        let groups = Dictionary(grouping: shown, by: Self.group)
        let sectionOrder = ["index", "map", "profile", "project", "decision", "error", "lesson", "technology", "rule", "preference", "skill", "tool", "task", "conversation", "file", "missing", "note"]
        return List(selection: $selectedID) {
            ForEach(sectionOrder.filter { groups[$0] != nil }, id: \.self) { kind in
                Section(sectionTitle(kind)) {
                    ForEach(groups[kind] ?? []) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).lineLimit(1)
                            Text(layerLabel(note) + (note.tags.isEmpty ? "" : " · " + note.tags.joined(separator: " · ")))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(note.id)
                        .opacity(note.resolved ? 1 : 0.5)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: AppCopy.text("vault.search"))
    }

    /// A finding is listed and coloured by what it is: a decision, a mistake or a lesson.
    /// The signed project decisions share the decisions' section.
    nonisolated static func group(_ note: MemoryNote) -> String {
        note.kind == "insight" ? (note.tags.dropFirst().first ?? "lesson") : note.kind
    }

    private func layerLabel(_ note: MemoryNote) -> String {
        note.layer == .user ? AppCopy.text("vault.layer.mac") : AppCopy.text("vault.layer.project")
    }

    private func sectionTitle(_ kind: String) -> String {
        switch kind {
        case "map": return AppCopy.text("memory.section.map")
        case "index": return AppCopy.text("vault.section.projects")
        case "task": return AppCopy.text("memory.section.tasks")
        case "decision": return AppCopy.text("memory.section.decisions")
        case "conversation": return AppCopy.text("memory.section.conversations")
        case "preference": return AppCopy.text("memory.section.preferences")
        case "profile": return AppCopy.text("vault.section.profile")
        case "project": return AppCopy.text("vault.section.project")
        case "rule": return AppCopy.text("vault.section.rules")
        case "technology": return AppCopy.text("vault.section.technologies")
        case "error": return AppCopy.text("vault.section.mistakes")
        case "lesson": return AppCopy.text("vault.section.lessons")
        case "tool": return AppCopy.text("vault.section.tools")
        case "skill": return AppCopy.text("vault.section.skills")
        default: return kind.capitalized
        }
    }

    // MARK: - Note detail

    @ViewBuilder
    private func noteDetail(_ vault: MemoryVault) -> some View {
        if let id = selectedID, let note = vault.notes.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(note.title).font(.title2.weight(.semibold))
                    Text(note.layer == .user
                        ? AppCopy.text("vault.layer.macHint")
                        : AppCopy.text("vault.layer.projectHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !note.path.isEmpty {
                        Text(note.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Divider()
                    if note.kind == "project" {
                        projectEditor(note)
                    } else if note.id == "learned_rules" {
                        rulesEditor()
                    } else {
                        rendered(note.body)
                            .textSelection(.enabled)
                        deleteControl(for: note)
                    }
                    if refused {
                        Text(AppCopy.text("vault.notSaved.credential"))
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                    if !note.backlinks.isEmpty {
                        Divider()
                        Text(AppCopy.text("memory.backlinks")).font(.headline)
                        ForEach(note.backlinks, id: \.self) { link in
                            Button(vault.notes.first { $0.id == link }?.title ?? link) { selectedID = link }
                                .buttonStyle(.link)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            ContentUnavailableView(
                AppCopy.text("memory.selectNote"),
                systemImage: "doc.text"
            )
        }
    }

    /// Deletion for the person's own notes. A project note is not offered here: its
    /// event stays in the signed log, so it can only be taken out of the prompt.
    @ViewBuilder
    private func deleteControl(for note: MemoryNote) -> some View {
        if note.layer == .user, let edit = permanentDelete(for: note) {
            Divider()
            Button(AppCopy.text("archive.deletePermanently"), role: .destructive) { pendingDelete = edit }
        }
    }

    /// A project note is not deleted from here: its editor has its own "remove from memory".
    private func permanentDelete(for note: MemoryNote) -> MemoryEdit? {
        note.kind == "project" ? nil : MemoryEdit.removal(of: note)
    }

    // MARK: - Editing

    private func save(_ edit: MemoryEdit) {
        refused = !bridge.editMemory(edit)
        if !refused { refreshTick += 1 }
    }

    private func editor(_ id: String, initial: String, minHeight: CGFloat) -> some View {
        TextEditor(text: $draft)
            .font(.body.monospaced())
            .frame(minHeight: minHeight)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .task(id: id) {
                draft = initial
                draftID = id
                refused = false
            }
    }

    /// One project entry: the brief the user gave, or what was learned from the
    /// code. Saving records it again under the same key. Removing it takes it out of
    /// the prompt; the signed event that set it stays in the log and in git history.
    private func projectEditor(_ note: MemoryNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            editor(note.id, initial: note.body, minHeight: 160)
            HStack {
                Button(AppCopy.text("common.save")) { save(.setProject(key: note.title, value: draft)) }
                    .disabled(draftID != note.id || draft == note.body)
                Button(AppCopy.text("vault.removeFromMemory"), role: .destructive) {
                    save(.forgetProject(key: note.title))
                    selectedID = nil
                }
                Spacer()
                Text("\(draft.count) / \(ProjectKnowledge.limit(forKey: note.title))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(draft.count > ProjectKnowledge.limit(forKey: note.title) ? .red : .secondary)
            }
            Text(AppCopy.text("vault.remove.hint"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The person's own rules, then every lesson with where it came from.
    private func rulesEditor() -> some View {
        let manual = bridge.manualRules
        let stats = bridge.learningStats
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(AppCopy.text("vault.rules.own")).font(.headline)
                Spacer()
                Button(AppCopy.text("vault.rules.add")) { newEntry = .rule }
            }
            Text(AppCopy.text("vault.rules.hint"))
            .font(.caption)
            .foregroundStyle(.secondary)
            editor("learned_rules", initial: manual, minHeight: 100)
            Button(AppCopy.text("common.save")) { save(.setManualRules(draft)) }
                .disabled(draftID != "learned_rules" || draft == manual)

            Divider()
            Text(AppCopy.text("vault.lessons.learned")).font(.headline)
            if bridge.lessons.isEmpty {
                Text(AppCopy.text("vault.lessons.empty")).foregroundStyle(.secondary)
            }
            ForEach(bridge.lessons, id: \.id) { lesson in
                lessonRow(lesson, uses: stats.uses.first { lesson.cited.hasPrefix("[" + $0.record + " ") }?.count ?? 0)
            }

            Divider()
            Text(AppCopy.text("vault.log.title")).font(.headline)
            Text(stats.turns == 0
                ? AppCopy.text("vault.log.empty")
                : AppCopy.format("vault.log.summary", stats.turns, stats.corrected, stats.corrected * 100 / stats.turns))
                .font(.callout)
        }
    }

    private func lessonRow(_ lesson: Lesson, uses: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if editingLesson == lesson.id {
                TextField("", text: $lessonDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(lesson.line).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Text([
                    lesson.isExplicit ? AppCopy.text("vault.lesson.user") : AppCopy.text("vault.lesson.inferred"),
                    AppCopy.format("vault.lesson.learned", lesson.hits),
                    AppCopy.format("vault.lesson.used", uses),
                    lesson.isActive() ? "" : AppCopy.text("vault.lesson.inactive"),
                    lesson.paths.joined(separator: ", "),
                ].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if editingLesson == lesson.id {
                    Button(AppCopy.text("common.save")) {
                        save(.editLesson(id: lesson.id, rule: lessonDraft))
                        editingLesson = nil
                    }
                    Button(AppCopy.text("common.cancel")) { editingLesson = nil }
                } else {
                    if !lesson.isExplicit {
                        Button(AppCopy.text("vault.lesson.pin")) { save(.pinLesson(id: lesson.id)) }
                    }
                    Button(AppCopy.text("sidebar.edit")) {
                        lessonDraft = lesson.rule
                        editingLesson = lesson.id
                    }
                    Button(AppCopy.text("common.delete"), role: .destructive) { save(.forgetLesson(id: lesson.id)) }
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Renders markdown, turning `[[id]]` into a tappable link that selects the
    /// target note. ponytail: line-by-line AttributedString, good enough for the
    /// short host-generated notes; not a full CommonMark renderer.
    private func rendered(_ body: String) -> some View {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = String(raw)
                if let attributed = try? AttributedString(
                    markdown: wikilinkToMarkdown(line),
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed)
                } else {
                    Text(line)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "mem" else { return .systemAction }
            selectedID = url.host?.removingPercentEncoding ?? url.host
            return .handled
        })
    }

    private func wikilinkToMarkdown(_ line: String) -> String {
        var result = ""
        var rest = Substring(line)
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            result += rest[..<open.lowerBound]
            let target = String(rest[open.upperBound..<close.lowerBound])
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target
            result += "[\(target)](mem://\(encoded))"
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }
}

// MARK: - New entries

/// What the "Yeni" menu can add. Each one lands in the layer it belongs to.
private enum NewEntry: String, Identifiable {
    case project, preference, rule
    var id: String { rawValue }
}

private struct NewEntrySheet: View {
    let bridge: AgentBridge
    let kind: NewEntry
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var scope: MemoryPreferenceScope = .everywhere
    @State private var refused = false

    private static let suggestedKeys = ["goal", "constraints", "out-of-scope", "architecture", "conventions", "design-system"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            switch kind {
            case .project:
                keyField
                Text(AppCopy.text("vault.entry.projectHint"))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $value).font(.body).frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("\(value.count) / \(ProjectKnowledge.limit(forKey: normalizedKey))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value.count > ProjectKnowledge.limit(forKey: normalizedKey) ? .red : .secondary)
            case .preference:
                TextField(AppCopy.text("vault.entry.keyLanguage"), text: $key)
                TextField(AppCopy.text("vault.entry.value"), text: $value)
                Picker(AppCopy.text("vault.entry.scope"), selection: $scope) {
                    Text(AppCopy.text("vault.entry.everywhere")).tag(MemoryPreferenceScope.everywhere)
                    Text(AppCopy.text("vault.entry.thisProject")).tag(MemoryPreferenceScope.thisProject)
                }
                .pickerStyle(.segmented)
                Text(AppCopy.text("vault.entry.preferenceHint"))
                    .font(.caption).foregroundStyle(.secondary)
            case .rule:
                TextEditor(text: $value).font(.body).frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text(AppCopy.text("vault.entry.ruleHint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if refused {
                Text(AppCopy.text("vault.notSaved.entry"))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(AppCopy.text("common.cancel"), role: .cancel) { dismiss() }
                Button(AppCopy.text("common.save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var title: String {
        switch kind {
        case .project: return AppCopy.text("vault.entry.newProject")
        case .preference: return AppCopy.text("vault.entry.newPreference")
        case .rule: return AppCopy.text("vault.entry.newRule")
        }
    }

    private var keyField: some View {
        HStack {
            TextField(AppCopy.text("vault.entry.keyGoal"), text: $key)
            Menu(AppCopy.text("vault.entry.suggest")) {
                ForEach(Self.suggestedKeys, id: \.self) { suggestion in
                    Button(suggestion) { key = suggestion }
                }
            }
            .fixedSize()
        }
    }

    private var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private var canSave: Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .project:
            return !normalizedKey.isEmpty && !text.isEmpty && value.count <= ProjectKnowledge.limit(forKey: normalizedKey)
        case .preference:
            return !normalizedKey.isEmpty && !text.isEmpty
        case .rule:
            return !text.isEmpty
        }
    }

    private func save() {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit: MemoryEdit
        switch kind {
        case .project: edit = .setProject(key: normalizedKey, value: text)
        case .preference: edit = .setPreference(key: normalizedKey, value: text, scope: scope)
        case .rule: edit = .addManualRule(text)
        }
        refused = !bridge.editMemory(edit)
        if !refused {
            onSaved()
            dismiss()
        }
    }
}

// MARK: - Graph

/// The graph's content. Stable layout coordinates let window resizing transform
/// existing drawing data without starting another force calculation.
private struct GraphLayoutKey: Equatable {
    let vault: MemoryVault
}

private struct GraphDrawingData {
    struct Node: Identifiable {
        let id: String
        let position: CGPoint
        let title: String
        let kind: String
        let degree: Int
        let color: Color
    }

    struct Edge {
        let path: Path
        let lineWidth: CGFloat
    }

    var nodes: [Node] = []
    var edges: [Edge] = []

    init() {}

    init(vault: MemoryVault, positions: [String: CGPoint]) {
        var degree: [String: Int] = [:]
        for edge in vault.edges {
            degree[edge.from, default: 0] += 1
            degree[edge.to, default: 0] += 1
        }
        edges = vault.edges.compactMap { edge in
            guard let from = positions[edge.from], let to = positions[edge.to] else { return nil }
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            let lineWidth = min(3, 1 + log2(CGFloat(max(1, edge.weight))) / 2)
            return Edge(path: path, lineWidth: lineWidth)
        }
        nodes = vault.notes.compactMap { note in
            guard let position = positions[note.id] else { return nil }
            let title = note.title.count > 32 ? String(note.title.prefix(31)) + "…" : note.title
            let kind = MemoryVaultView.group(note)
            return Node(
                id: note.id,
                position: position,
                title: title,
                kind: note.kind,
                degree: degree[note.id] ?? 0,
                color: Self.color(for: kind)
            )
        }
    }

    private static func color(for kind: String) -> Color {
        switch kind {
        case "task": return .blue
        case "decision": return .green
        case "conversation": return .teal
        case "index": return .orange
        case "map": return .purple
        case "preference", "profile": return .pink
        case "rule": return .cyan
        case "error": return .red
        case "lesson": return .mint
        case "file": return .gray
        case "technology": return .indigo
        case "tool": return .brown
        case "skill": return .yellow
        default: return .secondary
        }
    }
}

private struct GraphView: View {
    let vault: MemoryVault
    @Binding var selectedID: String?
    /// Notes the search matches; the rest are dimmed. Nil shows every note alike.
    var matches: Set<String>? = nil
    @Binding var showsAll: Bool
    /// Paths, labels and colors in stable, unzoomed graph coordinates.
    @State private var drawing = GraphDrawingData()
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag = CGSize.zero

    private static let zoomRange: ClosedRange<CGFloat> = 0.4...4

    var body: some View {
        GeometryReader { geo in
            let scale = Self.clamp(zoom * pinch)
            let offset = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
            let graphScale = Self.fitScale(for: geo.size) * scale
            Canvas { context, _ in
                guard graphScale > 0 else { return }
                var graphContext = context
                graphContext.translateBy(x: geo.size.width / 2 + offset.width, y: geo.size.height / 2 + offset.height)
                graphContext.scaleBy(x: graphScale, y: graphScale)
                graphContext.translateBy(
                    x: -ForceLayout.referenceSize.width / 2,
                    y: -ForceLayout.referenceSize.height / 2
                )
                for edge in drawing.edges {
                    graphContext.stroke(
                        edge.path,
                        with: .color(.secondary.opacity(0.35)),
                        lineWidth: edge.lineWidth / graphScale
                    )
                }
                for node in drawing.nodes {
                    let p = screenPoint(node.position, size: geo.size, graphScale: graphScale, offset: offset)
                    let selected = node.id == selectedID
                    // A project's root is the larger node its notes branch from.
                    let r: CGFloat = node.kind == "index" ? 9 : selected ? 7 : 5
                    let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                    let dimmed = matches.map { !$0.contains(node.id) } ?? false
                    context.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(dimmed ? 0.18 : 1)))
                    if selected {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.primary), lineWidth: 1.5)
                    }
                    // Every label at once piles up: the selected note, the roots, the hubs and the
                    // search's matches are named; the rest once zoomed in.
                    let hub = node.degree >= 8
                    if selected || node.kind == "index" || (matches != nil && !dimmed)
                        || (matches == nil && (hub || scale >= 1.6)) {
                        context.draw(
                            Text(node.title).font(.caption2).foregroundStyle(.secondary),
                            at: CGPoint(x: p.x, y: p.y + r + 7)
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = Self.clamp(zoom * value.magnification) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                    }
            )
            .onTapGesture { location in
                let hit = drawing.nodes
                    .map { ($0.id, screenPoint($0.position, size: geo.size, graphScale: graphScale, offset: offset)) }
                    .min { distance($0.1, location) < distance($1.1, location) }
                if let hit, distance(hit.1, location) < 22 { selectedID = hit.0 }
            }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .task(id: GraphLayoutKey(vault: vault)) {
                let notes = vault.notes.map(\.id)
                let edges = vault.edges.map { ($0.from, $0.to) }
                let layoutTask = Task.detached(priority: .userInitiated) {
                    AppBackgroundWorkLimiter.withCancellablePermit(isCancelled: { Task.isCancelled }) {
                        ForceLayout.positions(notes: notes, edges: edges, size: ForceLayout.referenceSize)
                    } ?? [:]
                }
                let laidOut = await withTaskCancellationHandler {
                    await layoutTask.value
                } onCancel: {
                    layoutTask.cancel()
                }
                guard !Task.isCancelled else { return }
                drawing = GraphDrawingData(vault: vault, positions: laidOut)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { showsAll.toggle() } label: {
                Image(systemName: showsAll ? "circle.hexagongrid.fill" : "circle.hexagongrid")
            }
            .help(AppCopy.text("archive.allProjects"))
            Button { zoom = Self.clamp(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(AppCopy.text("studio.zoomOut"))
            Button { zoom = Self.clamp(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(AppCopy.text("studio.zoomIn"))
            Button {
                zoom = 1
                pan = .zero
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help(AppCopy.text("vault.graph.reset"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
    }

    /// Fit stable reference coordinates to the viewport, then apply zoom and pan.
    private func screenPoint(_ point: CGPoint, size: CGSize, graphScale: CGFloat, offset: CGSize) -> CGPoint {
        return CGPoint(
            x: size.width / 2 + (point.x - ForceLayout.referenceSize.width / 2) * graphScale + offset.width,
            y: size.height / 2 + (point.y - ForceLayout.referenceSize.height / 2) * graphScale + offset.height
        )
    }

    private static func fitScale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        return min(size.width / ForceLayout.referenceSize.width, size.height / ForceLayout.referenceSize.height)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Deterministic Fruchterman-Reingold layout: the ideal spacing comes from the area per
/// node, the steps cool off, and a pull towards the centre keeps loose notes off the edges.
/// ponytail: O(n²) per iteration; fine for a few hundred notes, Barnes-Hut past that.
private enum ForceLayout {
    static let referenceSize = CGSize(width: 1200, height: 800)

    static func positions(notes: [String], edges: [(String, String)], size: CGSize) -> [String: CGPoint] {
        guard !notes.isEmpty, size.width > 0, size.height > 0 else { return [:] }
        // Index-based so the n² inner loop allocates nothing; duplicate ids collapse to one node.
        var index: [String: Int] = [:]
        var ids: [String] = []
        for id in notes where index[id] == nil {
            if ids.count.isMultiple(of: 64), Task.isCancelled { return [:] }
            index[id] = ids.count
            ids.append(id)
        }
        let n = ids.count
        var linked = [Bool](repeating: false, count: n * n)
        for (a, b) in edges {
            if Task.isCancelled { return [:] }
            guard let i = index[a], let j = index[b] else { continue }
            linked[i * n + j] = true
            linked[j * n + i] = true
        }
        let width = Double(size.width), height = Double(size.height)
        let cx = width / 2, cy = height / 2
        let radius = min(width, height) * 0.35
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if i.isMultiple(of: 64), Task.isCancelled { return [:] }
            let angle = Double(i) / Double(n) * 2 * .pi
            xs[i] = cx + cos(angle) * radius
            ys[i] = cy + sin(angle) * radius
        }
        let k = (width * height / Double(n)).squareRoot() * 0.75
        // Tuned on a vault-shaped graph: no node left on an edge, none closer than ~25pt.
        let gravity = 20 * k
        var temperature = width / 10
        var dxs = [Double](repeating: 0, count: n)
        var dys = [Double](repeating: 0, count: n)
        for _ in 0..<200 {
            if Task.isCancelled { return [:] }
            for a in 0..<n {
                if a.isMultiple(of: 8), Task.isCancelled { return [:] }
                var dx = 0.0, dy = 0.0
                let ax = xs[a], ay = ys[a], row = a * n
                for b in 0..<n where b != a {
                    if b.isMultiple(of: 128), Task.isCancelled { return [:] }
                    let ex = ax - xs[b], ey = ay - ys[b]
                    let d = max(0.01, (ex * ex + ey * ey).squareRoot())
                    var force = k * k / d
                    if linked[row + b] { force -= d * d / k }
                    dx += ex / d * force
                    dy += ey / d * force
                }
                dxs[a] = dx - (ax - cx) / cx * gravity
                dys[a] = dy - (ay - cy) / cy * gravity
            }
            for a in 0..<n {
                let length = max(0.01, (dxs[a] * dxs[a] + dys[a] * dys[a]).squareRoot())
                let step = min(length, temperature)
                xs[a] = min(max(16, xs[a] + dxs[a] / length * step), width - 16)
                ys[a] = min(max(16, ys[a] + dys[a] / length * step), height - 22)
            }
            temperature = max(temperature * 0.97, 0.5)
        }
        var pos: [String: CGPoint] = [:]
        for (i, id) in ids.enumerated() { pos[id] = CGPoint(x: xs[i], y: ys[i]) }
        return pos
    }
}
