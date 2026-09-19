// Copyright (c) 2026 DOTS
// Scheduled tasks trailing panel.

import SwiftUI
import DotsHarnessCore

struct TasksView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var scheduler: TaskScheduler

    @State private var selectedTaskID: String?
    @State private var draftTask: ScheduledTask?

    init(model: AppModel) {
        self.model = model
        self.scheduler = model.scheduler
    }

    var body: some View {
        VStack(spacing: 0) {
            if let task = detailTask {
                TaskDetailView(
                    model: model,
                    task: task,
                    runs: scheduler.runs(for: task.id),
                    onClose: closeDetail,
                    onSave: { saved in
                        scheduler.upsert(saved)
                        draftTask = nil
                        selectedTaskID = saved.id
                    },
                    onDelete: {
                        scheduler.delete(task.id)
                        closeDetail()
                    }
                )
            } else {
                taskList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailTask: ScheduledTask? {
        if let draftTask { return draftTask }
        guard let selectedTaskID else { return nil }
        return scheduler.tasks.first { $0.id == selectedTaskID }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    suggestions
                    tasks
                }
                .padding(16)
            }

            Divider()
            HStack {
                Button {
                    draftTask = ScheduledTask(
                        name: "",
                        cron: "0 */5 * * *",
                        prompt: "",
                        workspacePath: model.workspacePath
                    )
                } label: {
                    Label(AppCopy.text("tasks.add"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button(AppCopy.text("common.done")) {
                    model.isTasksPresented = false
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
        }
    }

    private var panelHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.text("tasks.title")).font(.headline)
                Text(AppCopy.text("tasks.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                model.isTasksPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(AppCopy.text("tasks.close"))
        }
        .padding(14)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.text("tasks.suggestions"))
                .font(.subheadline.weight(.semibold))

            ForEach(TaskSuggestion.all) { suggestion in
                Button {
                    let task = suggestion.task(workspacePath: model.workspacePath)
                    scheduler.upsert(task)
                    selectedTaskID = task.id
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: suggestion.icon)
                            .foregroundStyle(suggestion.color)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(AppCopy.text(suggestion.titleKey)).font(.callout.weight(.medium))
                                Text(suggestion.schedule).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(AppCopy.text(suggestion.detailKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.text("tasks.active")).font(.subheadline.weight(.semibold))
            if scheduler.tasks.isEmpty {
                Text(AppCopy.text("tasks.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ForEach(scheduler.tasks) { task in taskRow(task) }
            }
        }
    }

    private func taskRow(_ task: ScheduledTask) -> some View {
        HStack(spacing: 10) {
            Button {
                draftTask = nil
                selectedTaskID = task.id
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name.isEmpty ? task.cron : task.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(task.cron).font(.caption.monospaced())
                        Text(task.enabled ? AppCopy.text("tasks.enabled") : AppCopy.text("tasks.disabled"))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { task.enabled },
                set: { scheduler.setEnabled(task.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func closeDetail() {
        draftTask = nil
        selectedTaskID = nil
    }
}

private struct TaskSuggestion: Identifiable {
    let id: String
    let titleKey: String
    let detailKey: String
    let schedule: String
    let cron: String
    let promptKey: String
    let icon: String
    let color: Color

    func task(workspacePath: String) -> ScheduledTask {
        ScheduledTask(name: AppCopy.text(titleKey), cron: cron, prompt: AppCopy.text(promptKey), workspacePath: workspacePath)
    }

    static let all: [TaskSuggestion] = [
        TaskSuggestion(id: "daily-brief", titleKey: "tasks.suggestion.daily.title", detailKey: "tasks.suggestion.daily.detail", schedule: AppCopy.text("tasks.suggestion.daily.schedule"), cron: "0 8 * * 1-5", promptKey: "tasks.suggestion.daily.prompt", icon: "bell", color: .blue),
        TaskSuggestion(id: "weekly-review", titleKey: "tasks.suggestion.weekly.title", detailKey: "tasks.suggestion.weekly.detail", schedule: AppCopy.text("tasks.suggestion.weekly.schedule"), cron: "0 16 * * 5", promptKey: "tasks.suggestion.weekly.prompt", icon: "list.bullet.clipboard", color: .purple),
        TaskSuggestion(id: "follow-up", titleKey: "tasks.suggestion.followup.title", detailKey: "tasks.suggestion.followup.detail", schedule: AppCopy.text("tasks.suggestion.followup.schedule"), cron: "0 9 * * 1-5", promptKey: "tasks.suggestion.followup.prompt", icon: "arrow.uturn.right.circle", color: .green),
    ]
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
                .padding(16)
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
                            if !run.modelID.isEmpty { Text(run.modelID).font(.caption2).foregroundStyle(.secondary) }
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
        let selectedName = model.router.models.first(where: { $0.id == selection.wrappedValue })
            .map { RouterCatalog.modelDisplayName(for: $0) }
            ?? RouterCatalog.modelDisplayName(for: RouterModel(id: selection.wrappedValue))
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
        if let value = patch.modelID { task.modelID = value }
        if let value = patch.fallbackModelID { task.fallbackModelID = value }
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
