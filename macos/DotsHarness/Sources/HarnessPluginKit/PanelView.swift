// Copyright (c) 2026 DOTS
// Renders a declarative PanelNode tree as real SwiftUI.

import SwiftUI

@MainActor
public struct PanelView: View {
    private let node: PanelNode
    private let ctx: any PluginContext

    public init(node: PanelNode, ctx: any PluginContext) {
        self.node = node
        self.ctx = ctx
    }

    public var body: some View { render(node) }

    // AnyView: the tree is recursive, so an opaque return type can't be inferred.
    private func render(_ n: PanelNode) -> AnyView {
        switch n.type {
        case "vstack":
            return AnyView(VStack(alignment: .leading, spacing: 6) { kids(n) })
        case "hstack":
            return AnyView(HStack(spacing: 6) { kids(n) })
        case "text":
            return AnyView(Text(n.text ?? ""))
        case "button":
            let tool = n.tool ?? ""
            let args = n.args ?? [:]
            return AnyView(Button(n.label ?? "Run") {
                Task { _ = try? await ctx.tools.call(tool, arguments: args) }
            })
        case "field":
            return AnyView(TextField(n.placeholder ?? "", text: textBinding(n.key ?? "")))
        case "toggle":
            return AnyView(Toggle(n.label ?? "", isOn: flagBinding(n.key ?? "")))
        case "spacer":
            return AnyView(Spacer())
        case "image":
            if let raw = n.url, let url = URL(string: raw) {
                return AnyView(AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() })
            }
            return AnyView(EmptyView())
        default:
            return AnyView(EmptyView())
        }
    }

    private func kids(_ n: PanelNode) -> some View {
        ForEach(Array((n.children ?? []).enumerated()), id: \.offset) { _, child in
            render(child)
        }
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { ctx.settings.get(key)?.string ?? "" },
            set: { ctx.settings.set(key, .string($0)) }
        )
    }

    private func flagBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { ctx.settings.get(key)?.bool ?? false },
            set: { ctx.settings.set(key, .bool($0)) }
        )
    }
}
