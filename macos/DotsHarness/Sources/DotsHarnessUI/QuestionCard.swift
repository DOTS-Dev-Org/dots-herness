// Copyright (c) 2026 DOTS
// Native clarification card above the composer: suggested options plus a free-text answer per question.

import SwiftUI
import DotsHarnessCore

struct QuestionCard: View {
    let pending: PendingQuestion
    let onSubmit: ([String]) -> Void
    let onSkip: () -> Void

    @State private var selection: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var page = 0

    private var questions: [AskUserQuestion] { pending.questions }
    private var current: AskUserQuestion { questions[min(page, questions.count - 1)] }
    private var isLast: Bool { page >= questions.count - 1 }

    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("\(min(page, questions.count - 1) + 1)/\(questions.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                Text(current.prompt)
                    .font(.headline)
                    .lineLimit(collapsed ? 1 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                Button(action: onSkip) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(AppCopy.text("ask.skip"))
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(.secondary)

            if !collapsed {
                // Keep every answer visible without requiring a separate scroll gesture.
                optionRows(current)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    chip(AppCopy.text("ask.skipShort"), prominent: false, action: onSkip)
                    if isLast {
                        // Unanswered questions are sent as "undetermined".
                        chip(AppCopy.text("ask.submit"), prominent: true) {
                            onSubmit(questions.map { answer(for: $0) })
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        chip(AppCopy.text("ask.next"), prominent: true) { page += 1 }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
        .accessibilityElement(children: .contain)
    }

    private func chip(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    prominent ? Color.primary.opacity(0.32) : Color.primary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    /// "Title — detail" renders as a title with a dimmed second line.
    private func split(_ option: String) -> (String, String?) {
        guard let range = option.range(of: " — ") ?? option.range(of: ": ") else { return (option, nil) }
        return (String(option[..<range.lowerBound]), String(option[range.upperBound...]))
    }

    private func selectionIndicator(_ selected: Bool, allowsMultiple: Bool) -> some View {
        let symbol = allowsMultiple
            ? (selected ? "checkmark.square.fill" : "square")
            : (selected ? "circle.inset.filled" : "circle")
        return Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(selected ? Color.accentColor : .secondary)
    }

    private func rowBackground() -> some ShapeStyle { Color.primary.opacity(0.07) }

    private func toggle(_ option: String, for question: AskUserQuestion) {
        if question.allowsMultipleSelection {
            var selected = selection[question.id] ?? []
            if !selected.insert(option).inserted {
                selected.remove(option)
            }
            selection[question.id] = selected
        } else {
            selection[question.id] = [option]
        }
        custom[question.id] = ""
    }

    private func optionRows(_ question: AskUserQuestion) -> some View {
        VStack(spacing: 6) {
            ForEach(question.options, id: \.self) { option in
                let parts = split(option)
                let on = selection[question.id, default: []].contains(option)
                Button {
                    toggle(option, for: question)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parts.0).font(.body)
                            if let detail = parts.1 {
                                Text(detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        selectionIndicator(on, allowsMultiple: question.allowsMultipleSelection)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(rowBackground(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // A written answer always wins over the suggestions.
            let written = !(custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(AppCopy.text("ask.other")).font(.body)
                    Spacer(minLength: 8)
                    selectionIndicator(written, allowsMultiple: question.allowsMultipleSelection)
                }
                TextField(
                    AppCopy.text("ask.customPlaceholder"),
                    text: Binding(
                        get: { custom[question.id] ?? "" },
                        set: { value in
                            custom[question.id] = value
                            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                selection[question.id] = []
                            }
                        }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(rowBackground(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func answer(for question: AskUserQuestion) -> String {
        let written = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard written.isEmpty else { return written }
        let selected = question.options.filter { selection[question.id, default: []].contains($0) }
        return selected.joined(separator: "\n")
    }
}
