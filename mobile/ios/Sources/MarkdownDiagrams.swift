// Copyright (c) 2026 DOTS
// Colored ```diagram, ```flow and ```chart fences; same rules as shared/MarkdownDiagrams.cs.

import SwiftUI

/// A trailing `[tone: label]` or `[group]` tag. Status tones keep fixed colors.
struct DiagramTag: Equatable {
    let tone: String?
    let label: String

    static let statusColors: [String: Color] = [
        "ok": .green, "done": .green,
        "warn": .orange, "warning": .orange,
        "error": .red, "fail": .red,
        "info": .blue,
        "pending": .gray,
    ]
    static let palette: [Color] = [.teal, .indigo, .orange, .pink, .blue, .brown]

    var color: Color { Self.statusColors[tone?.lowercased() ?? ""] ?? .gray }

    /// `"Title: note [ok: Doğru]"` → `("Title: note", tag)`.
    static func split(_ line: String) -> (body: String, tag: DiagramTag?) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("]"), let open = trimmed.lastIndex(of: "[") else { return (trimmed, nil) }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        let body = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let parts = inner.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, !first.isEmpty else { return (body, nil) }
        if parts.count > 1 { return (body, DiagramTag(tone: first, label: parts[1])) }
        return (body, DiagramTag(tone: statusColors[first.lowercased()] == nil ? nil : first, label: first))
    }

    static func titleNote(_ body: String) -> (title: String, note: String) {
        let parts = body.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }
}

struct FlowStep: Equatable {
    let number: Int
    let title: String
    let note: String
    let badge: DiagramTag?
    let isLast: Bool

    static func parse(_ source: String) -> [FlowStep] {
        let lines = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.enumerated().map { index, line in
            let (body, badge) = DiagramTag.split(line)
            let (title, note) = DiagramTag.titleNote(body)
            return FlowStep(number: index + 1, title: title, note: note, badge: badge, isLast: index == lines.count - 1)
        }
    }
}

struct ChartBar: Equatable {
    let label: String
    let text: String
    let fraction: Double

    /// `label: number` rows scaled to the block's peak; other lines are skipped.
    static func parse(_ source: String) -> [ChartBar] {
        let rows = source.components(separatedBy: "\n").compactMap { line -> (String, String, Double)? in
            guard let colon = line.lastIndex(of: ":") else { return nil }
            let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let value = Double(text.prefix { $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
            return (line[..<colon].trimmingCharacters(in: .whitespaces), text, value)
        }
        let peak = rows.map { abs($0.2) }.max() ?? 0
        return rows.map { ChartBar(label: $0.0, text: $0.1, fraction: peak > 0 ? abs($0.2) / peak : 0) }
    }
}

/// ```diagram: one line per layer; `a: b [g] | c: d [g]`, `> caption`, `legend: g = text | …`.
struct DiagramSpec {
    struct Node: Equatable {
        let title: String
        let note: String
        let group: String?
    }
    struct Layer {
        let caption: String?
        let nodes: [Node]
    }
    var layers: [Layer] = []
    var legend: [(group: String, text: String)] = []

    init(source: String) {
        var caption: String?
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                caption = line.dropFirst().trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("legend:") {
                legend += line.dropFirst(7).split(separator: "|").compactMap { item in
                    let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return pair.count == 2 ? (pair[0], pair[1]) : nil
                }
            } else {
                let nodes = line.split(separator: "|").map { cell -> Node in
                    let (body, tag) = DiagramTag.split(String(cell))
                    let (title, note) = DiagramTag.titleNote(body)
                    return Node(title: title, note: note, group: tag?.label)
                }
                layers.append(Layer(caption: caption, nodes: nodes))
                caption = nil
            }
        }
    }

    /// Status names keep their fixed color; other groups take palette slots by first use.
    func color(for group: String?) -> Color {
        guard let group, !group.isEmpty else { return .gray }
        if let status = DiagramTag.statusColors[group.lowercased()] { return status }
        var seen: [String] = []
        for name in layers.flatMap({ $0.nodes.compactMap(\.group) }) + legend.map(\.group)
        where DiagramTag.statusColors[name.lowercased()] == nil && !seen.contains(name) {
            seen.append(name)
        }
        return DiagramTag.palette[(seen.firstIndex(of: group) ?? 0) % DiagramTag.palette.count]
    }
}

private func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

struct DiagramView: View {
    let spec: DiagramSpec

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(spec.layers.enumerated()), id: \.offset) { index, layer in
                if index > 0 {
                    Image(systemName: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if let caption = layer.caption {
                    Text(inlineMarkdown(caption))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                layerView(layer)
            }
            if !spec.legend.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { legendItems }
                    VStack(alignment: .leading, spacing: 4) { legendItems }
                }
                .padding(.top, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder
    private func layerView(_ layer: DiagramSpec.Layer) -> some View {
        if layer.nodes.count == 1, let node = layer.nodes.first {
            nodeView(node).frame(maxWidth: 360)
        } else {
            // idealWidth keeps ViewThatFits from measuring unwrapped text: a phone
            // stacks a layer only when its boxes cannot share the row.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(layer.nodes.enumerated()), id: \.offset) { _, node in
                        nodeView(node).frame(minWidth: 96, idealWidth: 96, maxWidth: .infinity)
                    }
                }
                VStack(spacing: 6) {
                    ForEach(Array(layer.nodes.enumerated()), id: \.offset) { _, node in nodeView(node) }
                }
            }
        }
    }

    private func nodeView(_ node: DiagramSpec.Node) -> some View {
        let tint = spec.color(for: node.group)
        return VStack(spacing: 2) {
            Text(inlineMarkdown(node.title))
                .font(.subheadline.weight(.semibold))
            if !node.note.isEmpty {
                Text(inlineMarkdown(node.note))
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.45)))
    }

    private var legendItems: some View {
        ForEach(spec.legend, id: \.group) { item in
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(spec.color(for: item.group).opacity(0.5))
                    .frame(width: 12, height: 12)
                Text(inlineMarkdown(item.text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FlowView: View {
    let steps: [FlowStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps, id: \.number) { step in
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
        }
        .font(.subheadline)
    }
}

struct ChartView: View {
    let bars: [ChartBar]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                HStack(spacing: 8) {
                    Text(bar.label).lineLimit(1).frame(width: 110, alignment: .leading)
                    ProgressView(value: bar.fraction)
                    Text(bar.text).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }
}
