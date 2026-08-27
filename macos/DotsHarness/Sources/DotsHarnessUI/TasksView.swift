// Copyright (c) 2026 DOTS
// Scheduled-task manager opened from the main toolbar.

import SwiftUI
import DotsHarnessCore

struct TasksView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var scheduler: TaskScheduler
    @Environment(\.dismiss) private var dismiss

    @State private var editing: ScheduledTask?
    @State private var isCreating = false

    init(model: AppModel) {
        self.model = model
        self.scheduler = model.scheduler
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if scheduler.tasks.isEmpty {
                Text(AppCopy.text("tasks.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(scheduler.tasks) { task in
                            row(task)
                        }
                    }
                }
            }

            HStack {
                Button {
                    isCreating = true
                } label: {
                    Label(AppCopy.text("tasks.add"), systemImage: "plus")
                }
                Spacer()
                Button(AppCopy.text("common.done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isCreating) {
            TaskEditor(
                task: ScheduledTask(
                    name: "",
                    cron: "0 */5 * * *",
                    prompt: "",
                    workspacePath: model.workspacePath
                ),
                title: AppCopy.text("tasks.add")
            ) { scheduler.upsert($0) }
        }
        .sheet(item: $editing) { task in
            TaskEditor(task: task, title: AppCopy.text("tasks.edit")) { scheduler.upsert($0) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.text("tasks.title")).font(.title3.weight(.semibold))
                Text(AppCopy.text("tasks.subtitle")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.name.isEmpty ? task.cron : task.name)
                    .font(.callout.weight(.semibold))
                Spacer()
                stateBadge(task.lastState)
                Toggle("", isOn: Binding(
                    get: { task.enabled },
                    set: { scheduler.setEnabled(task.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Text(task.cron)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            if let next = task.nextRun() {
                Text("\(AppCopy.text("tasks.cron.next")): \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(AppCopy.text("tasks.cron.invalid")).font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button(AppCopy.text("tasks.runNow")) { scheduler.runNow(task.id) }
                    .disabled(task.lastState == .running)
                Button(AppCopy.text("tasks.edit")) { editing = task }
                if let cid = task.lastConversationID {
                    Button(AppCopy.text("tasks.openConversation")) {
                        model.selectedConversationID = cid
                        dismiss()
                    }
                }
                Spacer()
                Button(role: .destructive) { scheduler.delete(task.id) } label: {
                    Text(AppCopy.text("tasks.delete"))
                }
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func stateBadge(_ state: ScheduledTask.RunState) -> some View {
        let (text, color): (String, Color) = {
            switch state {
            case .never: return (AppCopy.text("tasks.state.never"), .secondary)
            case .running: return (AppCopy.text("tasks.state.running"), .orange)
            case .ok: return (AppCopy.text("tasks.state.ok"), .green)
            case .failed: return (AppCopy.text("tasks.state.failed"), .red)
            }
        }()
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .help({ if case let .failed(message) = state { return message } else { return text } }())
    }
}

private struct TaskEditor: View {
    @State var task: ScheduledTask
    let title: String
    let onSave: (ScheduledTask) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))

            field(AppCopy.text("tasks.field.name")) {
                TextField("", text: $task.name)
            }
            field(AppCopy.text("tasks.field.cron")) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("0 */5 * * *", text: $task.cron)
                        .font(.body.monospaced())
                    cronPreview
                }
            }
            field(AppCopy.text("tasks.field.workspace")) {
                TextField("", text: $task.workspacePath)
            }
            field(AppCopy.text("tasks.field.prompt")) {
                TextEditor(text: $task.prompt)
                    .font(.body)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            }

            HStack {
                Spacer()
                Button(AppCopy.text("tasks.cancel")) { dismiss() }
                Button(AppCopy.text("tasks.save")) {
                    onSave(task)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var isValid: Bool {
        !task.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !task.workspacePath.trimmingCharacters(in: .whitespaces).isEmpty
            && task.expression != nil
    }

    @ViewBuilder
    private var cronPreview: some View {
        if let expression = task.expression {
            let runs = nextRuns(expression, count: 3)
            Text(runs.map { $0.formatted(date: .abbreviated, time: .shortened) }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(AppCopy.text("tasks.cron.invalid")).font(.caption).foregroundStyle(.red)
        }
    }

    private func nextRuns(_ expression: CronExpression, count: Int) -> [Date] {
        var out: [Date] = []
        var cursor = Date()
        for _ in 0..<count {
            guard let next = expression.nextDate(after: cursor) else { break }
            out.append(next)
            cursor = next
        }
        return out
    }

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
