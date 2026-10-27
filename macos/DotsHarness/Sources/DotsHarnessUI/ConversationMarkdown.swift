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
    private static let parsedCacheCostLimit = 8 * 1024 * 1024
    private static let maxCachedMarkdownBytes = 1024 * 1024
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
            /// A `stage: note [tone: badge]` row of a ```flow fence.
            var step: (number: Int, title: String, note: String, badge: DiagramTag?, isLast: Bool)?
            var isChartFence = false
        }
        let entries: [Entry]
        let blocks: [MarkdownBlock]
        init(entries: [Entry]) {
            self.entries = entries
            self.blocks = Self.makeBlocks(from: entries)
        }

        private static func makeBlocks(from entries: [Entry]) -> [MarkdownBlock] {
            var blocks: [MarkdownBlock] = []
            var index = 0
            while index < entries.count {
                let entry = entries[index]
                if !entry.isCode, index + 1 < entries.count, !entries[index + 1].isCode,
                   isTableRow(entry.line), let alignments = tableAlignments(entries[index + 1].line) {
                    let start = index
                    var rows: [[String]] = []
                    index += 2
                    while index < entries.count, !entries[index].isCode, isTableRow(entries[index].line) {
                        rows.append(tableCells(entries[index].line))
                        index += 1
                    }
                    blocks.append(.table(start, MarkdownTable(
                        header: tableCells(entry.line), alignments: alignments, rows: rows
                    )))
                    continue
                }
                guard entry.isCode, !entry.isChartFence, !isFence(entry.line) else {
                    blocks.append(.entry(index, entry))
                    index += 1
                    continue
                }
                let start = index
                var lines: [String] = []
                index += 1
                while index < entries.count, !isFence(entries[index].line) {
                    lines.append(entries[index].line)
                    index += 1
                }
                let isDiagram = entry.line.trimmingCharacters(in: .whitespaces) == "```diagram"
                blocks.append(isDiagram ? .diagram(start, DiagramSpec(lines: lines)) : .code(start, lines))
                index += 1 // closing fence, or the end of a reply still streaming
            }
            return blocks
        }

        private static func isFence(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }

        private static func isTableRow(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        }

        // ponytail: splits on every `|`, so a pipe inside inline code breaks the cell; `\|` escapes it.
        static func tableCells(_ line: String) -> [String] {
            var body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("|") { body.removeFirst() }
            if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
            return body.replacingOccurrences(of: "\\|", with: "\u{0}")
                .components(separatedBy: "|")
                .map { $0.replacingOccurrences(of: "\u{0}", with: "|").trimmingCharacters(in: .whitespaces) }
        }

        /// The `|---|:--:|` row under a table header, or nil when the line is anything else.
        static func tableAlignments(_ line: String) -> [HorizontalAlignment]? {
            guard isTableRow(line) else { return nil }
            let cells = tableCells(line)
            guard cells.allSatisfy({ cell in
                cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
            }) else { return nil }
            return cells.map { cell in
                switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
                case (true, true): return .center
                case (false, true): return .trailing
                default: return .leading
                }
            }
        }
    }

    private init() {
        // 48 thrashed once a transcript held more markdown bubbles than that: every
        // redraw re-parsed them all. The byte cost limit is what bounds memory.
        cache.countLimit = 512
        cache.totalCostLimit = Self.parsedCacheCostLimit
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
            for (number, index) in flowRows.enumerated() {
                let (body, badge) = DiagramTag.split(entries[index].line)
                let parts = body.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                entries[index].step = (
                    number + 1, parts.first ?? "", parts.count > 1 ? parts[1] : "",
                    badge, index == flowRows.last
                )
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
        let textBytes = text.utf8.count
        if store, textBytes <= Self.maxCachedMarkdownBytes {
            // Include the NSString key, source lines, attributed runs, and
            // grouped code/diagram blocks in the estimate. NSCache treats this
            // as a pressure hint, so oversized documents are excluded outright.
            let (textCost, textOverflow) = textBytes.multipliedReportingOverflow(by: 8)
            let (entryCost, entryOverflow) = entries.count.multipliedReportingOverflow(by: 256)
            let (cost, costOverflow) = textCost.addingReportingOverflow(entryCost)
            if !textOverflow, !entryOverflow, !costOverflow {
                cache.setObject(result, forKey: key, cost: max(cost, 1))
            }
        }
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
        cache.countLimit = 2_000
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    private func entry(for line: String, isCode: Bool, store: Bool) -> ParsedPlanMarkdown.Entry {
        let keyText = (isCode ? "c" : "t") + line
        let key = keyText as NSString
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
        let keyBytes = keyText.utf8.count
        if store, keyBytes <= 16 * 1024 {
            let (lineCost, overflow) = keyBytes.multipliedReportingOverflow(by: 4)
            let (cost, additionOverflow) = lineCost.addingReportingOverflow(256)
            if !overflow, !additionOverflow {
                lineCache.setObject(EntryBox(entry), forKey: key, cost: cost)
            }
        }
        return entry
    }

    private func parseMarkdown<S: StringProtocol>(_ line: S) -> AttributedString {
        guard var text = try? AttributedString(
            markdown: String(line),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(String(line)) }
        // Default inline code is body-size SF Mono, which reads larger and looser
        // than the prose around it. One step down, on a faint chip.
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(.callout, design: .monospaced)
            text[run.range].backgroundColor = Color.primary.opacity(0.07)
        }
        return text
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

/// One row of conversation markdown: a parsed line, or a whole plain ``` fence.
enum MarkdownBlock: Identifiable {
    case entry(Int, MarkdownCache.ParsedPlanMarkdown.Entry)
    case code(Int, [String])
    case diagram(Int, DiagramSpec)
    case table(Int, MarkdownTable)

    var id: Int {
        switch self {
        case .entry(let index, _), .code(let index, _), .diagram(let index, _), .table(let index, _):
            return index
        }
    }
}

struct PlanMarkdownView: View {
    let text: String
    var caches = true

    var body: some View {
        let parsed = MarkdownCache.shared.parsed(for: text, store: caches)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(parsed.blocks) { block in
                blockView(block)
            }
        }
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .entry(_, let entry): entryView(entry)
        case .code(_, let lines): CodeBlockView(lines: lines)
        case .diagram(_, let spec): DiagramView(spec: spec)
        case .table(_, let table): MarkdownTableView(table: table)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: MarkdownCache.ParsedPlanMarkdown.Entry) -> some View {
        if entry.isChartFence {
            EmptyView()
        } else if let step = entry.step {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(step.number)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inlineMarkdown(step.title)).fontWeight(.semibold)
                        if !step.note.isEmpty {
                            Text(inlineMarkdown(step.note)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let badge = step.badge {
                        Text(badge.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(badge.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(badge.color.opacity(0.15), in: Capsule())
                    }
                }
                .padding(.vertical, 6)
                if !step.isLast { Divider().padding(.leading, 26) }
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
                rich(heading.text)
                    .font(.title3.weight(.bold))
                    .padding(.top, 4)
                    .help(linkHoverHelp(in: heading.text))
            case 2:
                rich(heading.text)
                    .font(.body.weight(.semibold))
                    .padding(.top, 5)
                    .help(linkHoverHelp(in: heading.text))
            default:
                rich(heading.text)
                    .font(.callout.weight(.semibold))
                    .padding(.top, 3)
                    .help(linkHoverHelp(in: heading.text))
            }
        } else if let check = entry.checkState {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: check.checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(check.checked ? Color.accentColor : .secondary)
                rich(check.text).help(linkHoverHelp(in: check.text))
            }
        } else if let bullet = entry.bulletText {
            HStack(alignment: .top, spacing: 7) {
                Text("•")
                    .foregroundStyle(.secondary)
                rich(bullet).help(linkHoverHelp(in: bullet))
            }
        } else if let numbered = entry.numbered {
            HStack(alignment: .top, spacing: 7) {
                Text(numbered.number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                rich(numbered.text).help(linkHoverHelp(in: numbered.text))
            }
        } else if entry.line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            Text(entry.line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        } else if entry.line.isEmpty {
            Color.clear.frame(height: 2)
        } else if let attr = entry.attributed {
            rich(attr).help(linkHoverHelp(in: attr))
        } else {
            Text(entry.line)
        }
    }

    /// Codex-style file references: a document glyph ahead of each workspace file link.
    private func rich(_ text: AttributedString) -> Text {
        let runs = text.runs[\.link]
        guard runs.contains(where: { $0.0.flatMap(AppModel.fileLinkPath) != nil }) else { return Text(text) }
        return runs.reduce(Text(verbatim: "")) { result, run in
            let piece = Text(AttributedString(text[run.1]))
            guard run.0.flatMap(AppModel.fileLinkPath) != nil else { return Text("\(result)\(piece)") }
            let icon = Text(Image(systemName: "doc")).foregroundStyle(Color.accentColor)
            return Text("\(result)\(icon)\u{2009}\(piece)")
        }
    }

    private func linkHoverHelp(in text: AttributedString) -> String {
        text.runs.compactMap { run -> String? in
            guard let url = run.link else { return nil }
            let label = String(text[run.range].characters)
            if let path = AppModel.fileLinkPath(url) { return "\(label)\n\(path)" }
            let domain = url.host ?? url.absoluteString
            return "\(label)\n\(domain)\n\(url.absoluteString)"
        }
        .joined(separator: "\n\n")
    }
}

/// A plain fenced block. Lines stay unwrapped so box diagrams keep their columns;
/// the copy button sits in the header, top-right.
struct CodeBlockView: View {
    let lines: [String]

    var body: some View {
        let code = lines.joined(separator: "\n")
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                CopyFeedbackButton(text: code)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A GitHub-style pipe table: header row, `|---|` alignment row, body rows.
struct MarkdownTable {
    let header: [String]
    let alignments: [HorizontalAlignment]
    let rows: [[String]]
}

struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        let columns = table.header.count
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            row(table.header, columns: columns, isHeader: true)
            ForEach(table.rows.indices, id: \.self) { index in
                Divider().gridCellUnsizedAxes(.horizontal)
                row(table.rows[index], columns: columns, isHeader: false)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func row(_ cells: [String], columns: Int, isHeader: Bool) -> some View {
        GridRow {
            ForEach(0..<columns, id: \.self) { column in
                let alignment = column < table.alignments.count ? table.alignments[column] : .leading
                Text(inlineMarkdown(column < cells.count ? cells[column] : ""))
                    .fontWeight(isHeader ? .semibold : nil)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(isHeader ? Color.primary.opacity(0.06) : Color.clear)
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
