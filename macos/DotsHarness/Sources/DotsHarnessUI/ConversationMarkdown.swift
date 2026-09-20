// Copyright (c) 2026 DOTS
// Markdown/plan rendering cache and prompt drag-drop delegate for the conversation.

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore

@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()
    private let cache = NSCache<NSString, ParsedPlanMarkdown>()

    final class ParsedPlanMarkdown {
        struct Entry {
            let line: String
            let isCode: Bool
            let attributed: AttributedString?
            let numbered: (number: String, text: AttributedString)?
            let checkState: (checked: Bool, text: AttributedString)?
            let bulletText: AttributedString?
            let heading: (level: Int, text: AttributedString)?
        }
        let entries: [Entry]
        init(entries: [Entry]) {
            self.entries = entries
        }
    }

    private init() {
        cache.countLimit = 200
    }

    func parsed(for text: String) -> ParsedPlanMarkdown {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let lines = text.components(separatedBy: .newlines)
        var codeIndices = Set<Int>()
        var inCodeBlock = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                codeIndices.insert(index)
                inCodeBlock.toggle()
            } else if inCodeBlock {
                codeIndices.insert(index)
            }
        }
        var entries: [ParsedPlanMarkdown.Entry] = []
        for (index, line) in lines.enumerated() {
            let isCode = codeIndices.contains(index)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var attributed: AttributedString?
            var numbered: (number: String, text: AttributedString)?
            var checkState: (checked: Bool, text: AttributedString)?
            var bulletText: AttributedString?
            var heading: (level: Int, text: AttributedString)?

            if !isCode {
                if trimmed.hasPrefix("### ") {
                    heading = (3, parseMarkdown(trimmed.dropFirst(4)))
                } else if trimmed.hasPrefix("## ") {
                    heading = (2, parseMarkdown(trimmed.dropFirst(3)))
                } else if trimmed.hasPrefix("# ") {
                    heading = (1, parseMarkdown(trimmed.dropFirst(2)))
                } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                    let checked = trimmed.dropFirst(3).first == "x" || trimmed.dropFirst(3).first == "X"
                    checkState = (checked, parseMarkdown(trimmed.dropFirst(6)))
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    bulletText = parseMarkdown(trimmed.dropFirst(2))
                } else if let item = parseNumberedItem(trimmed) {
                    numbered = (item.number, parseMarkdown(item.text))
                } else if !trimmed.hasPrefix("```") && !line.isEmpty {
                    attributed = parseMarkdown(line)
                }
            }

            entries.append(ParsedPlanMarkdown.Entry(
                line: line,
                isCode: isCode,
                attributed: attributed,
                numbered: numbered,
                checkState: checkState,
                bulletText: bulletText,
                heading: heading
            ))
        }
        let result = ParsedPlanMarkdown(entries: entries)
        cache.setObject(result, forKey: key)
        return result
    }

    private func parseMarkdown<S: StringProtocol>(_ line: S) -> AttributedString {
        (try? AttributedString(
            markdown: String(line),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(String(line))
    }

    private func parseNumberedItem(_ line: String) -> (number: String, text: String)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isNumber { index += 1 }
        guard index > 0, index + 1 < characters.count,
              characters[index] == ".", characters[index + 1] == " " else { return nil }
        return (
            String(characters[..<(index + 1)]),
            String(characters[(index + 2)...])
        )
    }
}

struct PlanMarkdownView: View {
    let text: String

    var body: some View {
        let parsed = MarkdownCache.shared.parsed(for: text)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parsed.entries.enumerated()), id: \.offset) { _, entry in
                entryView(entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func entryView(_ entry: MarkdownCache.ParsedPlanMarkdown.Entry) -> some View {
        if entry.isCode {
            Text(entry.line.isEmpty ? " " : entry.line)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if let heading = entry.heading {
            switch heading.level {
            case 1:
                Text(heading.text)
                    .font(.title3.weight(.bold))
                    .padding(.top, 4)
            case 2:
                Text(heading.text)
                    .font(.body.weight(.semibold))
                    .padding(.top, 5)
            default:
                Text(heading.text)
                    .font(.callout.weight(.semibold))
                    .padding(.top, 3)
            }
        } else if let check = entry.checkState {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: check.checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(check.checked ? Color.accentColor : .secondary)
                Text(check.text)
            }
        } else if let bullet = entry.bulletText {
            HStack(alignment: .top, spacing: 7) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(bullet)
            }
        } else if let numbered = entry.numbered {
            HStack(alignment: .top, spacing: 7) {
                Text(numbered.number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(numbered.text)
            }
        } else if entry.line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            Text(entry.line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        } else if entry.line.isEmpty {
            Text(" ")
                .font(.caption)
        } else if let attr = entry.attributed {
            Text(attr)
        } else {
            Text(entry.line)
        }
    }
}

struct PendingPromptDropDelegate: DropDelegate {
    @Binding var draggedPromptID: String?
    let targetPromptID: String?
    let conversationID: String
    let bridge: AgentBridge

    func dropEntered(info: DropInfo) {
        guard let draggedPromptID else { return }
        bridge.movePendingPrompt(
            draggedPromptID,
            relativeTo: targetPromptID,
            in: conversationID
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedPromptID = nil
        return true
    }
}
