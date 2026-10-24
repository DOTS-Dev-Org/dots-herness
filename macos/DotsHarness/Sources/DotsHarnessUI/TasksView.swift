// Copyright (c) 2026 DOTS
// Tasks section: the scheduled task list beside a task's detail or the planner landing.

import SwiftUI
import DotsHarnessCore

struct TasksView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var scheduler: TaskScheduler

    @State private var selectedTaskID: String?
    @State private var draftTask: ScheduledTask?
    @State private var suggestions: [ScheduledTaskSuggestion] = []
    @State private var isPersonalizing = false
    @State private var suggestionRefresh = 0
    @State private var loadedSuggestionRefresh = 0
    @State private var suggestionRequestID = UUID()

    init(model: AppModel) {
        self.model = model
        self.scheduler = model.scheduler
    }

    var body: some View {
        HStack(spacing: 0) {
            taskList
                .frame(width: 230)
            Divider()
            if let task = scheduler.tasks.first(where: { $0.id == selectedTaskID }) {
                TaskDetailView(
                    model: model,
                    task: task,
                    runs: scheduler.runs(for: task.id),
                    onClose: { selectedTaskID = nil },
                    onSave: { scheduler.upsert($0) },
                    onDelete: {
                        scheduler.delete(task.id)
                        selectedTaskID = nil
                    }
                )
                .id(task.id)
            } else {
                landing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $draftTask) { draft in
            NewTaskSheet(model: model, task: draft) { created in
                scheduler.upsert(created)
                selectedTaskID = created.id
            }
        }
        .task(id: "\(model.workspacePath)|\(model.appLocale.identifier)|\(model.bridge.memoryRevision)|\(suggestionRefresh)") {
            await loadSuggestions()
        }
    }

    // MARK: List

    /// Soonest first; paused or unschedulable tasks sink to the bottom.
    private var upcoming: [(task: ScheduledTask, next: Date?)] {
        scheduler.tasks
            .map { ($0, $0.enabled ? $0.nextRun() : nil) }
            .sorted { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppCopy.text("rail.tasks"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Button(action: startDraft) {
                HStack(spacing: 9) {
                    Image(systemName: "plus").frame(width: 20)
                    Text(AppCopy.text("tasks.new"))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            Text(AppCopy.text("tasks.upcoming"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 17)
                .padding(.top, 16)
                .padding(.bottom, 6)

            if scheduler.tasks.isEmpty {
                Text(AppCopy.text("tasks.empty"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 17)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(upcoming, id: \.task.id) { entry in taskRow(entry.task, next: entry.next) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func taskRow(_ task: ScheduledTask, next: Date?) -> some View {
        Button { selectedTaskID = task.id } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name.isEmpty ? task.cron : task.name)
                        .lineLimit(1)
                    Text(next?.formatted(date: .abbreviated, time: .shortened) ?? AppCopy.text(task.enabled ? "tasks.cron.invalid" : "tasks.disabled"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if task.lastState == .running { ProgressView().controlSize(.small) }
            }
            .opacity(task.enabled ? 1 : 0.55)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(task.id == selectedTaskID ? 0.1 : 0),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(AppCopy.text("tasks.runNow")) { scheduler.runNow(task.id) }
                .disabled(task.lastState == .running)
            Toggle(AppCopy.text("tasks.enabled"), isOn: Binding(
                get: { task.enabled },
                set: { scheduler.setEnabled(task.id, $0) }
            ))
            Divider()
            Button(AppCopy.text("tasks.delete"), role: .destructive) {
                scheduler.delete(task.id)
                if selectedTaskID == task.id { selectedTaskID = nil }
            }
        }
    }

    // MARK: Landing

    private var landing: some View {
        GeometryReader { geometry in
            let layout = TaskSuggestionLayout(size: geometry.size)
            VStack(spacing: layout.spacing) {
                VStack(spacing: 8) {
                    if layout.mascotHeight > 0 {
                        clockMascot
                            .frame(width: layout.mascotHeight * 1.3, height: layout.mascotHeight)
                            .accessibilityHidden(true)
                    }
                    Text(AppCopy.text("tasks.plan.title"))
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(AppCopy.text("tasks.plan.subtitle"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(height: layout.headerHeight)

                HStack(spacing: 8) {
                    if isPersonalizing { ProgressView().controlSize(.small) }
                    Text(AppCopy.text("tasks.suggestions"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { suggestionRefresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help(AppCopy.text("tasks.suggestions.refresh"))
                        .disabled(isPersonalizing)
                }
                .frame(height: 24)

                if layout.horizontal {
                    DraggableTaskCards(contentSize: CGSize(
                        width: CGFloat(displayedSuggestions.count) * (layout.cardWidth + 14) - 14,
                        height: layout.cardHeight)) {
                        HStack(spacing: 14) {
                            ForEach(displayedSuggestions) { suggestion in
                                suggestionCard(suggestion, layout: layout)
                            }
                        }
                    }
                    .frame(height: layout.cardsHeight)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(displayedSuggestions) { suggestion in
                            suggestionCard(suggestion, layout: layout)
                        }
                    }
                    .frame(height: layout.cardsHeight)
                }
            }
            .frame(width: layout.contentWidth)
            .padding(.vertical, layout.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var displayedSuggestions: [ScheduledTaskSuggestion] {
        suggestions.isEmpty ? ScheduledTaskSuggestion.defaults : suggestions
    }

    private func suggestionCard(_ suggestion: ScheduledTaskSuggestion, layout: TaskSuggestionLayout) -> some View {
        SuggestionCard(suggestion: suggestion) {
            draftTask = suggestion.task(workspacePath: model.workspacePath)
        }
        .frame(width: layout.cardWidth, height: layout.cardHeight)
    }

    @ViewBuilder
    private var clockMascot: some View {
        if let url = Bundle.module.url(forResource: "HerNessClockMascot", withExtension: "png"),
           let image = ImageFileCache.image(at: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "clock").font(.system(size: 36)).foregroundStyle(.secondary)
        }
    }

    private func loadSuggestions() async {
        let requestID = UUID()
        suggestionRequestID = requestID
        let force = loadedSuggestionRefresh != suggestionRefresh
        loadedSuggestionRefresh = suggestionRefresh
        let memory = model.bridge.taskSuggestionMemory
        // Last saved cards stay up while personalization runs silently; only a
        // manual refresh shows progress.
        suggestions = ScheduledTaskSuggestions.stored(memory: memory, locale: model.appLocale.identifier,
                                                      workspace: model.workspacePath) ?? ScheduledTaskSuggestion.defaults
        isPersonalizing = false
        guard !memory.isEmpty else { return }
        isPersonalizing = force
        defer { if suggestionRequestID == requestID { isPersonalizing = false } }
        do {
            let result = try await ScheduledTaskSuggestions.personalized(memory: memory,
                locale: model.appLocale.identifier, workspace: model.workspacePath,
                router: model.router, force: force)
            try Task.checkCancellation()
            guard suggestionRequestID == requestID else { return }
            suggestions = result
        } catch {
            guard !Task.isCancelled, suggestionRequestID == requestID else { return }
        }
    }

    private func startDraft() {
        draftTask = ScheduledTask(name: "", cron: "0 9 * * *", prompt: "", workspacePath: model.workspacePath)
    }
}

/// A ready-made task. The dashed outline marks it as a template, not a task that exists yet.
private struct SuggestionCard: View {
    let suggestion: ScheduledTaskSuggestion
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(suggestion.color)
                    .frame(width: 46, height: 50)
                    .background(suggestion.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(suggestion.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(suggestion.schedule)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Create form: instructions, a plain-language schedule, and the rarely needed settings folded away.
private struct NewTaskSheet: View {
    @ObservedObject var model: AppModel
    let onCreate: (ScheduledTask) -> Void
    @State private var task: ScheduledTask
    @State private var recurrence: TaskRecurrence
    @State private var showsAdvanced: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, task: ScheduledTask, onCreate: @escaping (ScheduledTask) -> Void) {
        self.model = model
        self.onCreate = onCreate
        self._task = State(initialValue: task)
        self._recurrence = State(initialValue: TaskRecurrence(cron: task.cron))
        // Without a usable workspace the task cannot be created, so show where to fix it.
        self._showsAdvanced = State(initialValue: task.resolvedTargetPath() == nil)
    }

    /// The task as it would be saved: schedule applied, name taken from the instructions if unset.
    private var built: ScheduledTask {
        var result = task
        result.cron = recurrence.cron
        if result.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let firstLine = result.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isNewline }
            result.name = String(firstLine.prefix(48))
        }
        return result
    }

    private var isValid: Bool {
        let candidate = built
        return !candidate.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && candidate.expression != nil
            && candidate.resolvedTargetPath() != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppCopy.text("tasks.plan.title")).font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(AppCopy.text("tasks.cancel"))
            }

            TextEditor(text: $task.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .overlay(alignment: .topLeading) {
                    if task.prompt.isEmpty {
                        Text(AppCopy.text("tasks.instructions"))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .modifier(FormGroup())
                .accessibilityLabel(AppCopy.text("tasks.field.prompt"))

            VStack(spacing: 0) {
                formRow(AppCopy.text("tasks.repeat")) {
                    Picker("", selection: $recurrence.kind) {
                        ForEach(TaskRecurrence.Kind.allCases) { kind in
                            Text(AppCopy.text("tasks.repeat.\(kind.rawValue)")).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if recurrence.kind == .weekly {
                    Divider().padding(.horizontal, 14)
                    formRow(AppCopy.text("tasks.day")) {
                        Picker("", selection: $recurrence.weekday) {
                            ForEach(Array(weekdayNames.enumerated()), id: \.offset) { index, name in
                                Text(name).tag(index)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if recurrence.kind == .custom {
                    Divider().padding(.horizontal, 14)
                    formRow(AppCopy.text("tasks.field.cron")) {
                        TextField("0 */5 * * *", text: $recurrence.custom)
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                            .frame(width: 160)
                    }
                } else if recurrence.kind != .hourly {
                    Divider().padding(.horizontal, 14)
                    formRow(AppCopy.text("tasks.time")) {
                        DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .fixedSize()
                    }
                }
            }
            .modifier(FormGroup())
            .onChange(of: recurrence.kind) { old, new in
                // Start the raw expression from what the form was showing.
                guard new == .custom else { return }
                var previous = recurrence
                previous.kind = old
                recurrence.custom = previous.cron
            }

            if let next = built.nextRun() {
                Text("\(AppCopy.text("tasks.cron.next")): \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(AppCopy.text("tasks.cron.invalid")).font(.caption).foregroundStyle(.red)
            }

            Button { showsAdvanced.toggle() } label: {
                HStack(spacing: 5) {
                    Text(AppCopy.text("tasks.advanced"))
                    Image(systemName: showsAdvanced ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if showsAdvanced {
                VStack(spacing: 0) {
                    formRow(AppCopy.text("tasks.field.workspace")) {
                        TextField("/path/to/workspace", text: $task.workspacePath)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                            .foregroundStyle(task.resolvedTargetPath() == nil ? Color.red : Color.primary)
                    }
                    Divider().padding(.horizontal, 14)
                    formRow(AppCopy.text("tasks.field.model")) {
                        ChatModelMenu(router: model.router, modelID: $task.modelID).fixedSize()
                    }
                    Divider().padding(.horizontal, 14)
                    formRow(AppCopy.text("tasks.field.fallback")) {
                        ChatModelMenu(router: model.router, modelID: $task.fallbackModelID).fixedSize()
                    }
                    Divider().padding(.horizontal, 14)
                    formRow(AppCopy.text("tasks.network")) {
                        Toggle("", isOn: $task.allowsNetwork).labelsHidden().toggleStyle(.switch)
                    }
                }
                .modifier(FormGroup())
            }

            HStack {
                Spacer()
                Button(AppCopy.text("tasks.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppCopy.text("tasks.create")) {
                    onCreate(built)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 520)
    }

    private var weekdayNames: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = model.appLocale
        return calendar.standaloneWeekdaySymbols
    }

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: recurrence.hour, minute: recurrence.minute, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                recurrence.hour = parts.hour ?? 9
                recurrence.minute = parts.minute ?? 0
            }
        )
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 0)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
    }
}

private struct FormGroup: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private extension ScheduledTaskSuggestion {
    var icon: String {
        switch id {
        case "daily": "sun.max.fill"
        case "email": "envelope.fill"
        case "reading": "book.fill"
        case "prices": "tag.fill"
        case "events": "music.note"
        case "weekend": "calendar"
        case "weekly": "doc.text.fill"
        default: "bell.fill"
        }
    }
    var color: Color {
        switch id {
        case "daily", "weekend": .orange
        case "email", "weekly": .blue
        case "reading": .purple
        case "prices": .green
        case "events": .red
        default: .pink
        }
    }
}

private struct TaskDetailView: View {
    @ObservedObject var model: AppModel
    @State private var task: ScheduledTask
    let runs: [ScheduledTaskRun]
    let onClose: () -> Void
    let onSave: (ScheduledTask) -> Void
    let onDelete: () -> Void

    init(model: AppModel, task: ScheduledTask, runs: [ScheduledTaskRun], onClose: @escaping () -> Void, onSave: @escaping (ScheduledTask) -> Void, onDelete: @escaping () -> Void) {
        self.model = model
        self._task = State(initialValue: task)
        self.runs = runs
        self.onClose = onClose
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Label(AppCopy.text("tasks.back"), systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(AppCopy.text("tasks.delete"))
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(task.name.isEmpty ? AppCopy.text("tasks.new") : task.name)
                        .font(.title3.weight(.semibold))
                    field(AppCopy.text("tasks.field.name")) { TextField(AppCopy.text("tasks.field.name"), text: $task.name) }
                    field(AppCopy.text("tasks.field.cron")) {
                        TextField("0 */5 * * *", text: $task.cron).font(.body.monospaced())
                        cronPreview
                    }
                    field(AppCopy.text("tasks.field.workspace")) { TextField("/path/to/workspace", text: $task.workspacePath) }
                    field(AppCopy.text("tasks.field.target")) {
                        TextField(AppCopy.text("tasks.field.targetHint"), text: $task.targetPath)
                        if !task.targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, task.resolvedTargetPath() == nil {
                            Text(AppCopy.text("tasks.target.invalid")).font(.caption).foregroundStyle(.red)
                        }
                    }
                    field(AppCopy.text("tasks.field.prompt")) {
                        TextEditor(text: $task.prompt)
                            .font(.body)
                            .frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    }
                    modelMenu(title: AppCopy.text("tasks.field.model"), selection: $task.modelID)
                    modelMenu(title: AppCopy.text("tasks.field.fallback"), selection: $task.fallbackModelID)
                    Toggle(AppCopy.text("tasks.network"), isOn: $task.allowsNetwork)
                    Toggle(AppCopy.text("tasks.enabled"), isOn: $task.enabled)

                    HStack {
                        Button(AppCopy.text("tasks.runNow")) { onSave(task); model.scheduler.runNow(task.id) }
                            .disabled(task.lastState == .running)
                        Spacer()
                        Button(AppCopy.text("tasks.save")) { onSave(task) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isValid)
                    }

                    runHistory
                    TaskAssistantView(model: model, task: $task, onSave: onSave)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var isValid: Bool {
        !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !task.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && task.expression != nil
            && task.resolvedTargetPath() != nil
    }

    @ViewBuilder private var cronPreview: some View {
        if let next = task.nextRun() {
            Text("\(AppCopy.text("tasks.cron.next")): \(next.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(AppCopy.text("tasks.cron.invalid")).font(.caption).foregroundStyle(.red)
        }
    }

    private var runHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.text("tasks.history")).font(.subheadline.weight(.semibold))
            if runs.isEmpty {
                Text(AppCopy.text("tasks.history.empty")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: run.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(run.ok ? .green : .red)
                            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption.weight(.medium))
                            Spacer()
                            if !run.modelID.isEmpty { Text(model.router.modelLabel(forID: run.modelID)).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(run.output).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                    .padding(9)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func modelMenu(title: String, selection: Binding<String>) -> some View {
        let selectedName = model.router.modelLabel(forID: selection.wrappedValue)
        return HStack {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button(AppCopy.text("modelPicker.auto")) { selection.wrappedValue = "" }
                ForEach(RouterCatalog.modelGroups(for: model.router.models)) { group in
                    Section {
                        ForEach(group.models) { option in
                            Button(RouterCatalog.modelDisplayName(for: option)) { selection.wrappedValue = option.id }
                        }
                    } header: {
                        Label(group.name, systemImage: group.logoSymbol)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selection.wrappedValue.isEmpty ? AppCopy.text("modelPicker.auto") : selectedName)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
        }
    }

    @ViewBuilder private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct TaskAssistantView: View {
    @ObservedObject var model: AppModel
    @Binding var task: ScheduledTask
    let onSave: (ScheduledTask) -> Void
    @State private var input = ""
    @State private var isSending = false
    @State private var messages: [TaskAssistantMessage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppCopy.text("tasks.assistant.title"), systemImage: "bubble.left.and.sparkles")
                .font(.subheadline.weight(.semibold))
            if !messages.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { message in
                            Text(message.text)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                                .padding(8)
                                .background(message.isUser ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(AppCopy.text("tasks.assistant.placeholder"), text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button { send() } label: { Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill") }
                    .buttonStyle(.borderless)
                    .disabled(isSending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func send() {
        let request = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isSending else { return }
        input = ""
        messages.append(TaskAssistantMessage(text: request, isUser: true))
        isSending = true
        let current = task
        Task { @MainActor in
            defer { isSending = false }
            do {
                let response = try await model.router.complete(
                    messages: [
                        AgentMessage(role: .system, content: """
                        You edit one scheduled task. Do not use tools and do not edit files. Return JSON only with optional keys: name, cron, prompt, workspacePath, targetPath, modelID, fallbackModelID, allowsNetwork, enabled. Use null for fields that should not change. Current task: \(Self.taskJSON(current)).
                        """),
                        AgentMessage(role: .user, content: request),
                    ],
                    model: current.modelID.isEmpty ? nil : current.modelID
                )
                if let patch = Self.decodePatch(response.message.content) {
                    apply(patch)
                    onSave(task)
                    messages.append(TaskAssistantMessage(text: AppCopy.text("tasks.assistant.updated"), isUser: false))
                } else {
                    messages.append(TaskAssistantMessage(text: response.message.content, isUser: false))
                }
            } catch {
                messages.append(TaskAssistantMessage(text: error.localizedDescription, isUser: false))
            }
        }
    }

    private func apply(_ patch: TaskAssistantPatch) {
        if let value = patch.name { task.name = value }
        if let value = patch.cron { task.cron = value }
        if let value = patch.prompt { task.prompt = value }
        if let value = patch.workspacePath { task.workspacePath = value }
        if let value = patch.targetPath { task.targetPath = value }
        // The patch is model output, so its model ids are only trusted as far as
        // the catalog agrees; anything else falls back to automatic routing.
        if let value = patch.modelID { task.modelID = model.router.usableModelID(value) }
        if let value = patch.fallbackModelID { task.fallbackModelID = model.router.usableModelID(value) }
        if let value = patch.allowsNetwork { task.allowsNetwork = value }
        if let value = patch.enabled { task.enabled = value }
    }

    private static func taskJSON(_ task: ScheduledTask) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(task), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func decodePatch(_ text: String) -> TaskAssistantPatch? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return try? JSONDecoder().decode(TaskAssistantPatch.self, from: Data(text[start...end].utf8))
    }
}

private struct TaskAssistantMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

private struct TaskAssistantPatch: Codable {
    let name: String?
    let cron: String?
    let prompt: String?
    let workspacePath: String?
    let targetPath: String?
    let modelID: String?
    let fallbackModelID: String?
    let allowsNetwork: Bool?
    let enabled: Bool?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        cron = try values.decodeIfPresent(String.self, forKey: .cron)
        prompt = try values.decodeIfPresent(String.self, forKey: .prompt)
        workspacePath = try values.decodeIfPresent(String.self, forKey: .workspacePath)
        targetPath = try values.decodeIfPresent(String.self, forKey: .targetPath)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
        fallbackModelID = try values.decodeIfPresent(String.self, forKey: .fallbackModelID)
        allowsNetwork = try values.decodeIfPresent(Bool.self, forKey: .allowsNetwork)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
    }
}
