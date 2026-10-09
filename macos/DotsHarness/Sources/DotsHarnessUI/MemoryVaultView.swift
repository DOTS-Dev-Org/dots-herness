// Copyright (c) 2026 DOTS
// Obsidian-style browser for the workspace `.mem` vault: searchable note list,
// rendered note with clickable [[wikilinks]], backlinks, and a force-directed
// link graph. Task, decision and map notes are host-generated and read-only;
// project entries, the user's own rules and the learned lessons are edited here.

import AppKit
import SwiftUI
import DotsHarnessCore

public struct MemoryVaultView: View {
    let bridge: AgentBridge
    @State private var selectedID: String?
    @State private var refreshTick = 0
    @State private var search = ""
    /// Text being edited, and the note or lesson it belongs to.
    @State private var draft = ""
    @State private var draftID: String?
    @State private var lessonDraft = ""
    @State private var editingLesson: String?
    @State private var refused = false

    public init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        let vault = bridge.memoryVault
        return Group {
            if !bridge.memoryReady || vault.notes.isEmpty {
                ContentUnavailableView(
                    AppCopy.text("memory.vault.title"),
                    systemImage: "brain",
                    description: Text(AppCopy.text("memory.notInitialized"))
                )
            } else {
                content(vault)
            }
        }
        .navigationTitle(AppCopy.text("settings.tab.memory"))
        .toolbar {
            ToolbarItemGroup {
                Button(AppCopy.text("memory.refresh")) { refreshTick += 1 }
                if bridge.memoryFolderURL != nil {
                    Button(AppCopy.text("memory.reveal")) {
                        if let url = bridge.memoryFolderURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
        }
        .id(refreshTick)
    }

    private func content(_ vault: MemoryVault) -> some View {
        VSplitView {
            GraphView(vault: vault, selectedID: $selectedID)
                .frame(minHeight: 180, idealHeight: 240)

            HSplitView {
                noteList(vault)
                    .frame(minWidth: 200, idealWidth: 260)
                noteDetail(vault)
                    .frame(minWidth: 320)
            }
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
        let groups = Dictionary(grouping: shown, by: \.kind)
        let sectionOrder = ["map", "index", "profile", "project", "rule", "preference", "task", "conversation", "decision", "file", "missing", "note"]
        return List(selection: $selectedID) {
            ForEach(sectionOrder.filter { groups[$0] != nil }, id: \.self) { kind in
                Section(sectionTitle(kind)) {
                    ForEach(groups[kind] ?? []) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).lineLimit(1)
                            if !note.tags.isEmpty {
                                Text(note.tags.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(note.id)
                        .opacity(note.resolved ? 1 : 0.5)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: tr("Hafızada ara", "Search memory"))
    }

    private func tr(_ turkish: String, _ english: String) -> String {
        AppCopy.language == .tr ? turkish : english
    }

    private func sectionTitle(_ kind: String) -> String {
        switch kind {
        case "map": return AppCopy.text("memory.section.map")
        case "index": return AppCopy.text("memory.section.index")
        case "task": return AppCopy.text("memory.section.tasks")
        case "decision": return AppCopy.text("memory.section.decisions")
        case "conversation": return AppCopy.text("memory.section.conversations")
        case "preference": return AppCopy.text("memory.section.preferences")
        case "project": return tr("Proje bilgisi", "Project knowledge")
        case "rule": return tr("Kurallar ve dersler", "Rules and lessons")
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
                    }
                    if refused {
                        Text(tr(
                            "Kaydedilmedi: metin bir kimlik bilgisine benziyor. Hafıza modele gönderilir ve depoyla birlikte commit edilir.",
                            "Not saved: that looks like a credential. Memory is sent to the model and committed with the repository."
                        ))
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                    if !note.backlinks.isEmpty {
                        Divider()
                        Text(AppCopy.text("memory.backlinks")).font(.headline)
                        ForEach(note.backlinks, id: \.self) { link in
                            Button(link) { selectedID = link }
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
    /// code. Saving records it again under the same key; forgetting takes it out
    /// of the prompt, and for a knowledge entry lets the agent learn it afresh.
    private func projectEditor(_ note: MemoryNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            editor(note.id, initial: note.body, minHeight: 160)
            HStack {
                Button(tr("Kaydet", "Save")) { save(.setProject(key: note.title, value: draft)) }
                    .disabled(draftID != note.id || draft == note.body)
                Button(tr("Unut", "Forget"), role: .destructive) {
                    save(.forgetProject(key: note.title))
                    selectedID = nil
                }
                Spacer()
                Text("\(draft.count) / \(ProjectKnowledge.limit(forKey: note.title))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(draft.count > ProjectKnowledge.limit(forKey: note.title) ? .red : .secondary)
            }
        }
    }

    /// The user's own rules, then every lesson with where it came from.
    private func rulesEditor() -> some View {
        let manual = bridge.manualRules
        let stats = bridge.learningStats
        return VStack(alignment: .leading, spacing: 12) {
            Text(tr("Kendi kurallarınız", "Your own rules")).font(.headline)
            Text(tr(
                "Buraya yazdığınız her şey bu projedeki her isteğe eklenir.",
                "Everything written here is added to every request in this project."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            editor("learned_rules", initial: manual, minHeight: 100)
            Button(tr("Kaydet", "Save")) { save(.setManualRules(draft)) }
                .disabled(draftID != "learned_rules" || draft == manual)

            Divider()
            Text(tr("Öğrenilen dersler", "Learned lessons")).font(.headline)
            if bridge.lessons.isEmpty {
                Text(tr("Henüz ders yok.", "No lessons yet.")).foregroundStyle(.secondary)
            }
            ForEach(bridge.lessons, id: \.id) { lesson in
                lessonRow(lesson, uses: stats.uses.first { lesson.cited.hasPrefix("[" + $0.record + " ") }?.count ?? 0)
            }

            Divider()
            Text(tr("Öğrenme günlüğü", "Learning log")).font(.headline)
            Text(stats.turns == 0
                ? tr("Henüz kayıtlı tur yok.", "No turns logged yet.")
                : tr(
                    "\(stats.turns) tur kaydedildi; \(stats.corrected) tanesi düzeltildi veya geri alındı (%\(stats.corrected * 100 / stats.turns)).",
                    "\(stats.turns) turns logged; \(stats.corrected) were corrected or undone (\(stats.corrected * 100 / stats.turns)%)."
                ))
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
                    lesson.isExplicit ? tr("kullanıcı", "user") : tr("çıkarım", "inferred"),
                    tr("\(lesson.hits) kez öğrenildi", "learned \(lesson.hits)×"),
                    tr("\(uses) kez kullanıldı", "used \(uses)×"),
                    lesson.isActive() ? "" : tr("artık uygulanmıyor", "no longer applied"),
                    lesson.paths.joined(separator: ", "),
                ].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if editingLesson == lesson.id {
                    Button(tr("Kaydet", "Save")) {
                        save(.editLesson(id: lesson.id, rule: lessonDraft))
                        editingLesson = nil
                    }
                    Button(tr("Vazgeç", "Cancel")) { editingLesson = nil }
                } else {
                    if !lesson.isExplicit {
                        Button(tr("Sabitle", "Pin")) { save(.pinLesson(id: lesson.id)) }
                    }
                    Button(tr("Düzenle", "Edit")) {
                        lessonDraft = lesson.rule
                        editingLesson = lesson.id
                    }
                    Button(tr("Unut", "Forget"), role: .destructive) { save(.forgetLesson(id: lesson.id)) }
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

// MARK: - Graph

private struct GraphView: View {
    let vault: MemoryVault
    @Binding var selectedID: String?

    var body: some View {
        GeometryReader { geo in
            let layout = ForceLayout.positions(
                notes: vault.notes.map(\.id),
                edges: vault.edges.map { ($0.from, $0.to) },
                size: geo.size
            )
            Canvas { context, _ in
                for edge in vault.edges {
                    guard let a = layout[edge.from], let b = layout[edge.to] else { continue }
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                }
                for note in vault.notes {
                    guard let p = layout[note.id] else { continue }
                    let selected = note.id == selectedID
                    let r: CGFloat = selected ? 7 : 5
                    let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(color(for: note.kind)))
                    if selected {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.primary), lineWidth: 1.5)
                    }
                    context.draw(
                        Text(note.title).font(.caption2).foregroundStyle(.secondary),
                        at: CGPoint(x: p.x, y: p.y + r + 7)
                    )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let hit = layout.min { lhs, rhs in
                    distance(lhs.value, location) < distance(rhs.value, location)
                }
                if let hit, distance(hit.value, location) < 22 { selectedID = hit.key }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "task": return .blue
        case "decision": return .green
        case "conversation": return .teal
        case "index": return .orange
        case "map": return .purple
        case "preference", "profile": return .pink
        case "rule": return .red
        case "file": return .gray
        default: return .secondary
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Tiny deterministic spring layout. ponytail: O(n²) per iteration, fixed
/// iteration count — fine for a vault of tens of notes; swap for a real
/// layout only if vaults grow into the thousands.
private enum ForceLayout {
    static func positions(notes: [String], edges: [(String, String)], size: CGSize) -> [String: CGPoint] {
        guard !notes.isEmpty, size.width > 0, size.height > 0 else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.35
        var pos: [String: CGPoint] = [:]
        for (i, id) in notes.enumerated() {
            let angle = Double(i) / Double(notes.count) * 2 * .pi
            pos[id] = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        let adjacency = Set(edges.map { [$0.0, $0.1].sorted().joined(separator: "\u{1}") })
        for _ in 0..<140 {
            var disp: [String: CGVector] = [:]
            for a in notes {
                var dx = 0.0, dy = 0.0
                for b in notes where b != a {
                    let pa = pos[a]!, pb = pos[b]!
                    var d = hypot(pa.x - pb.x, pa.y - pb.y)
                    if d < 0.01 { d = 0.01 }
                    let repulse = 2600 / (d * d)
                    dx += (pa.x - pb.x) / d * repulse
                    dy += (pa.y - pb.y) / d * repulse
                    let key = [a, b].sorted().joined(separator: "\u{1}")
                    if adjacency.contains(key) {
                        let attract = (d * d) / 9000
                        dx -= (pa.x - pb.x) / d * attract
                        dy -= (pa.y - pb.y) / d * attract
                    }
                }
                disp[a] = CGVector(dx: dx, dy: dy)
            }
            for a in notes {
                var p = pos[a]!
                let v = disp[a]!
                p.x = min(max(12, p.x + max(-8, min(8, v.dx))), size.width - 12)
                p.y = min(max(12, p.y + max(-8, min(8, v.dy))), size.height - 18)
                pos[a] = p
            }
        }
        return pos
    }
}
