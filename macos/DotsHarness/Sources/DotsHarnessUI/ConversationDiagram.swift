// Copyright (c) 2026 DOTS
// Colored ```diagram fences and ```flow badges in conversation markdown.

import SwiftUI

/// A trailing `[tone: label]` / `[group]` tag. Status tones keep fixed colors so
/// "ok" reads green in every reply; other names share a palette by first use.
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

    /// `"Title: note [ok: Doğru]"` → `("Title: note", tag)`; no tag when the line
    /// does not end in brackets.
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
}

/// ```diagram: one line per layer, top to bottom, arrows between layers.
///   `title: note [group] | title: note [group]`  nodes of one layer
///   `> caption`                                   label above the next layer
///   `legend: group = meaning | group = meaning`   color key
struct DiagramSpec {
    struct Node {
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

    init(lines: [String]) {
        var caption: String?
        for raw in lines {
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
                    let parts = body.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return Node(title: parts.first ?? "", note: parts.count > 1 ? parts[1] : "", group: tag?.label)
                }
                layers.append(Layer(caption: caption, nodes: nodes))
                caption = nil
            }
        }
    }

    /// Status names keep their fixed color; any other group takes the next palette slot.
    func color(for group: String?) -> Color {
        guard let group, !group.isEmpty else { return .gray }
        if let status = DiagramTag.statusColors[group.lowercased()] { return status }
        var seen: [String] = []
        for name in layers.flatMap({ $0.nodes.compactMap(\.group) }) + legend.map(\.group)
        where DiagramTag.statusColors[name.lowercased()] == nil && !seen.contains(name) {
            seen.append(name)
        }
        let slot = seen.firstIndex(of: group) ?? 0
        return DiagramTag.palette[slot % DiagramTag.palette.count]
    }
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
                // Wide: one line. Narrow: stacked.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { legendItems }
                    VStack(alignment: .leading, spacing: 4) { legendItems }
                }
                .padding(.top, 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder
    private func layerView(_ layer: DiagramSpec.Layer) -> some View {
        if layer.nodes.count == 1, let node = layer.nodes.first {
            nodeView(node).frame(maxWidth: 360)
        } else {
            // idealWidth keeps ViewThatFits from measuring unwrapped text: a layer
            // goes vertical only when its boxes truly cannot share the row.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(layer.nodes.enumerated()), id: \.offset) { _, node in
                        nodeView(node).frame(minWidth: 110, idealWidth: 110, maxWidth: .infinity)
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
                .font(.callout.weight(.semibold))
            if !node.note.isEmpty {
                Text(inlineMarkdown(node.note))
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true) // wrap, never truncate
        .padding(.horizontal, 10)
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

/// Inline Markdown (code spans, emphasis) for diagram and flow labels.
func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}
