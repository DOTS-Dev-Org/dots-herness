// Copyright (c) 2026 DOTS
// Chat message body. Prose wraps; fenced blocks stay unwrapped so box diagrams
// keep their columns, and each block gets a copy button in its header.

import SwiftUI
import UIKit

/// One piece of a chat message: prose, or the body of a ``` fence.
struct MarkdownSegment: Equatable {
    let isCode: Bool
    let text: String
    /// The fence tag (`diagram`, `flow`, `chart`); empty for prose and plain fences.
    /// A pipe table in prose comes out as code with language `table`; read it with ``MarkdownTable/init(_:)``.
    var language = ""
}

/// A GitHub-style pipe table: header row, `|---|` alignment row, body rows.
struct MarkdownTable: Equatable {
    let header: [String]
    let alignments: [TextAlignment]
    let rows: [[String]]

    init(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        header = Self.cells(lines[0])
        alignments = lines.count > 1 ? Self.alignments(lines[1]) ?? [] : []
        rows = lines.dropFirst(2).map(Self.cells)
    }

    static func isRow(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    // ponytail: splits on every `|`, so a pipe inside inline code breaks the cell; `\|` escapes it.
    static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        return body.replacingOccurrences(of: "\\|", with: "\u{0}")
            .components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: "\u{0}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// The `|---|:--:|` row under a table header, or nil when the line is anything else.
    static func alignments(_ line: String) -> [TextAlignment]? {
        guard isRow(line) else { return nil }
        let cells = cells(line)
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

enum MarkdownSegments {
    /// An unclosed fence stays code while a reply is still streaming.
    static func split(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false
        var language = ""

        func addProse(_ lines: ArraySlice<String>) {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(MarkdownSegment(isCode: false, text: body))
            }
        }

        // A table header still waiting for its `|---|` row stays prose until that row streams in.
        func flushProse() {
            var start = 0
            var index = 0
            while index + 1 < prose.count {
                guard MarkdownTable.isRow(prose[index]), MarkdownTable.alignments(prose[index + 1]) != nil else {
                    index += 1
                    continue
                }
                var end = index + 2
                while end < prose.count, MarkdownTable.isRow(prose[end]) { end += 1 }
                addProse(prose[start..<index])
                let table = prose[index..<end].map { $0.trimmingCharacters(in: .whitespaces) }
                segments.append(MarkdownSegment(isCode: true, text: table.joined(separator: "\n"), language: "table"))
                start = end
                index = end
            }
            addProse(prose[start...])
            prose.removeAll()
        }

        func flushCode() {
            if !code.isEmpty {
                segments.append(MarkdownSegment(isCode: true, text: code.joined(separator: "\n"), language: language))
            }
            code.removeAll()
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    flushProse()
                    language = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces).lowercased()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { flushCode() } else { flushProse() }
        return segments
    }
}

struct MarkdownBodyView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownSegments.split(text).enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    switch segment.language {
                    case "diagram": DiagramView(spec: DiagramSpec(source: segment.text))
                    case "flow": FlowView(steps: FlowStep.parse(segment.text))
                    case "chart" where !ChartBar.parse(segment.text).isEmpty:
                        ChartView(bars: ChartBar.parse(segment.text))
                    case "table": MarkdownTableView(table: MarkdownTable(segment.text))
                    default: MarkdownCodeBlockView(code: segment.text)
                    }
                } else {
                    Text(segment.text)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Equal-width columns so long cells wrap instead of overflowing the bubble.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            row(table.header, isHeader: true)
            ForEach(table.rows.indices, id: \.self) { index in
                Divider().gridCellUnsizedAxes(.horizontal)
                row(table.rows[index], isHeader: false)
            }
        }
        .font(.subheadline)
        .textSelection(.enabled)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(table.header.indices, id: \.self) { column in
                let alignment = column < table.alignments.count ? table.alignments[column] : .leading
                Text(inline(column < cells.count ? cells[column] : ""))
                    .fontWeight(isHeader ? .semibold : nil)
                    .multilineTextAlignment(alignment)
                    .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .background(isHeader ? Color.secondary.opacity(0.12) : Color.clear)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct MarkdownCodeBlockView: View {
    let code: String
    @EnvironmentObject private var localization: MobileLocalization
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localization.text("conversation.copy"))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
