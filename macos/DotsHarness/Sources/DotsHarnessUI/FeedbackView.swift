// Copyright (c) 2026 DOTS
// Feedback capture sheet for completed assistant and plan messages.

import DotsHarnessCore
import SwiftUI

struct FeedbackSheet: View {
    let target: FeedbackTarget
    let existing: FeedbackRecord?
    let onSubmit: (FeedbackType, [String], String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTags: Set<FeedbackTag>
    @State private var comment: String
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    init(
        target: FeedbackTarget,
        existing: FeedbackRecord?,
        onSubmit: @escaping (FeedbackType, [String], String) throws -> Void
    ) {
        self.target = target
        self.existing = existing
        self.onSubmit = onSubmit
        let initialTags = existing?.feedbackType == target.feedbackType
            ? existing?.tags.compactMap(FeedbackTag.init(rawValue:)) ?? []
            : []
        _selectedTags = State(initialValue: Set(initialTags))
        _comment = State(initialValue: existing?.feedbackType == target.feedbackType ? existing?.userComment ?? "" : "")
    }

    private var tags: [FeedbackTag] { FeedbackTag.tags(for: target.feedbackType) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Text(AppCopy.text("feedback.title"))
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppCopy.text("feedback.close"))
                .accessibilityLabel(AppCopy.text("feedback.close"))
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(tags) { tag in
                    tagButton(tag)
                }
            }

            ZStack(alignment: .topLeading) {
                if comment.isEmpty {
                    Text(AppCopy.text("feedback.commentPlaceholder"))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $comment)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 96, maxHeight: 150)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
            }

            Text(AppCopy.text("feedback.disclaimer"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer(minLength: 0)
                Button {
                    submit()
                } label: {
                    Text(AppCopy.text("feedback.submit"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 320)
    }

    private func tagButton(_ tag: FeedbackTag) -> some View {
        let isSelected = selectedTags.contains(tag)
        return Button {
            if isSelected {
                selectedTags.remove(tag)
            } else {
                selectedTags.insert(tag)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark" : "plus")
                    .font(.caption.weight(.semibold))
                Text(AppCopy.text(tag.titleKey))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.04),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .accessibilityLabel(AppCopy.text(tag.titleKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try onSubmit(
                target.feedbackType,
                selectedTags.map(\.rawValue).sorted(),
                comment.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSubmitting = false
        }
    }
}
