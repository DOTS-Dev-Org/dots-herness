// Copyright (c) 2026 DOTS
// Plan-mode clarification card: suggested options plus a free-text answer per question.

import SwiftUI
import DotsHarnessCore

struct QuestionCard: View {
    let pending: PendingQuestion
    let onSubmit: ([String]) -> Void
    let onSkip: () -> Void

    @State private var selection: [String: String] = [:]
    @State private var custom: [String: String] = [:]

    var body: some View {
        ComposerBanner {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 18, weight: .medium))
                Text(AppCopy.text("ask.title"))
                    .font(.headline)
                Spacer(minLength: 8)
                Text(AppCopy.format("ask.count", pending.questions.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(pending.questions) { question in
                questionBlock(question)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(AppCopy.text("ask.skip"), action: onSkip)
                    .buttonStyle(.plain)
                Button(AppCopy.text("ask.submit")) {
                    onSubmit(pending.questions.map { answer(for: $0) })
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.16), in: Capsule())
                .buttonStyle(.plain)
                .disabled(!isComplete)
                .opacity(isComplete ? 1 : 0.5)
            }
        }
        }
    }

    private func questionBlock(_ question: AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(question.header.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(question.prompt)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options, id: \.self) { option in
                Button {
                    selection[question.id] = option
                    custom[question.id] = ""
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selection[question.id] == option
                            ? "largecircle.fill.circle"
                            : "circle")
                            .foregroundStyle(selection[question.id] == option ? Color.accentColor : .secondary)
                        Text(option)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.primary.opacity(selection[question.id] == option ? 0.1 : 0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // A written answer always wins over the suggestions.
            TextField(
                AppCopy.text("ask.customPlaceholder"),
                text: Binding(
                    get: { custom[question.id] ?? "" },
                    set: { value in
                        custom[question.id] = value
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            selection[question.id] = nil
                        }
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func answer(for question: AskUserQuestion) -> String {
        let written = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return written.isEmpty ? (selection[question.id] ?? "") : written
    }

    private var isComplete: Bool {
        pending.questions.allSatisfy { !answer(for: $0).isEmpty }
    }
}
