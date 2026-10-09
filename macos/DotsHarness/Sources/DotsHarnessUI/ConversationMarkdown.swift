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
            /// A `label: number` row of a ```chart fence, scaled to the block's peak.
            var bar: (label: String, text: String, fraction: Double)?
            /// A `stage: note` row of a ```flow fence.
            var step: (title: String, note: String, isLast: Bool)?
            var isChartFence = false
        }
        let entries: [Entry]
        init(entries: [Entry]) {
            self.entries = entries
        }
    }

    private init() {
        cache.countLimit = 200
    }

    /// `store: false` for a reply still being written: every partial text is a new key.
    func parsed(for text: String, store: Bool = true) -> ParsedPlanMarkdown {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let lines = text.components(separatedBy: .newlines)
        var entries: [ParsedPlanMarkdown.Entry] = []
        entries.reserveCapacity(lines.count)
        var inCodeBlock = false
        var inChart = false
        var inFlow = false
        var flowRows: [Int] = []
        var chartRows: [(index: Int, row: (label: String, text: String, value: Double))] = []
        func flushChart() {
            let peak = chartRows.map { abs($0.row.value) }.max() ?? 0
            for (index, row) in chartRows {
                entries[index].bar = (row.label, row.text, peak > 0 ? abs(row.value) / peak : 0)
            }
            chartRows.removeAll()
            for index in flowRows {
                let parts = entries[index].line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                entries[index].step = (parts[0], parts.count > 1 ? parts[1] : "", index == flowRows.last)
            }
            flowRows.removeAll()
        }
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```")
            let isCode = isFence || inCodeBlock
            let closesChart = isFence && (inChart || inFlow)
            if isFence {
                inCodeBlock.toggle()
                inChart = inCodeBlock && trimmed == "```chart"
                inFlow = inCodeBlock && trimmed == "```flow"
            }
            // The last line of a live reply is still growing; every other line
            // is final, so each publish parses one line instead of the whole text.
            entries.append(entry(for: line, isCode: isCode, store: store || index < lines.count - 1))
            if inChart || inFlow || closesChart {
                if isFence {
                    entries[entries.count - 1].isChartFence = true
                } else if inFlow {
                    if !trimmed.isEmpty { flowRows.append(entries.count - 1) }
                } else if let row = Self.chartRow(trimmed) {
                    chartRows.append((entries.count - 1, row))
                }
            }
            if closesChart { flushChart() }
        }
        flushChart() // a chart still streaming has no closing fence yet
        let result = ParsedPlanMarkdown(entries: entries)
        if store { cache.setObject(result, forKey: key) }
        return result
    }

    nonisolated static func chartRow(_ line: String) -> (label: String, text: String, value: Double)? {
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let value = Double(text.prefix { $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return (line[..<colon].trimmingCharacters(in: .whitespaces), text, value)
    }

    private final class EntryBox {
        let entry: ParsedPlanMarkdown.Entry
        init(_ entry: ParsedPlanMarkdown.Entry) { self.entry = entry }
    }
    private let lineCache: NSCache<NSString, EntryBox> = {
        let cache = NSCache<NSString, EntryBox>()
        cache.countLimit = 4_000
        return cache
    }()

    private func entry(for line: String, isCode: Bool, store: Bool) -> ParsedPlanMarkdown.Entry {
        let key = ((isCode ? "c" : "t") + line) as NSString
        if let cached = lineCache.object(forKey: key) { return cached.entry }
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

        let entry = ParsedPlanMarkdown.Entry(
            line: line,
            isCode: isCode,
            attributed: attributed,
            numbered: numbered,
            checkState: checkState,
            bulletText: bulletText,
            heading: heading
        )
        if store { lineCache.setObject(EntryBox(entry), forKey: key) }
        return entry
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
    var caches = true

    var body: some View {
        let parsed = MarkdownCache.shared.parsed(for: text, store: caches)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parsed.entries.enumerated()), id: \.offset) { _, entry in
                entryView(entry)
            }
        }
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func entryView(_ entry: MarkdownCache.ParsedPlanMarkdown.Entry) -> some View {
        if entry.isChartFence {
            EmptyView()
        } else if let step = entry.step {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: step.isLast ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(step.title).fontWeight(.semibold)
                Text(step.note).foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if let bar = entry.bar {
            HStack(spacing: 8) {
                Text(bar.label)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
                ProgressView(value: bar.fraction)
                Text(bar.text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if entry.isCode {
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
            Color.clear.frame(height: 2)
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
