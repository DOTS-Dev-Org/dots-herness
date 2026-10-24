// Copyright (c) 2026 DOTS
// Add, test, and toggle MCP servers whose tools the agent can call.

import SwiftUI
import DotsHarnessCore
import HarnessPluginKit

struct MCPSettingsView: View {
    @ObservedObject var registry: MCPRegistry

    @State private var name = ""
    @State private var transport: MCPTransportKind = .http
    @State private var url = ""
    @State private var command = ""
    @State private var argumentsText = ""
    @State private var token = ""
    @State private var autoRunReadOnly = false
    @State private var testMessage: String?

    var body: some View {
        Form {
            Section(AppCopy.text("mcp.servers")) {
                if registry.servers.isEmpty {
                    Text(AppCopy.text("mcp.empty")).foregroundStyle(.secondary)
                }
                ForEach(registry.statuses) { status in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.name).fontWeight(.medium)
                            Text(stateText(status.state))
                                .font(.caption)
                                .foregroundStyle(stateColor(status.state))
                        }
                        Spacer()
                        if status.state == .needsAuthorization {
                            Button(AppCopy.text("market.signIn")) { Task { await registry.signIn(status.id) } }
                        } else if registry.hasOAuthGrant(status.id) {
                            Button(AppCopy.text("sidebar.signOut")) { registry.signOut(status.id); Task { await registry.connect(status.id) } }
                        }
                        Button(AppCopy.text("mcp.reconnect")) { Task { await registry.connect(status.id) } }
                        Button(AppCopy.text("common.remove"), role: .destructive) { registry.remove(status.id) }
                    }
                }
            }

            if !registry.logLines.isEmpty {
                Section(AppCopy.text("mcp.log")) {
                    ScrollView {
                        Text(registry.logLines.suffix(50).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }

            Section(AppCopy.text("mcp.add")) {
                TextField(AppCopy.text("custom.name"), text: $name)
                Picker(AppCopy.text("mcp.transport"), selection: $transport) {
                    Text("HTTP").tag(MCPTransportKind.http)
                    Text("stdio").tag(MCPTransportKind.stdio)
                }
                if transport == .http {
                    TextField("URL", text: $url)
                    SecureField(AppCopy.text("mcp.token"), text: $token)
                    Text(AppCopy.text("mcp.token.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField(AppCopy.text("mcp.command"), text: $command)
                    TextField(AppCopy.text("mcp.arguments"), text: $argumentsText)
                }
                Toggle(AppCopy.text("mcp.autoRunReadOnly"), isOn: $autoRunReadOnly)

                if let testMessage {
                    Text(testMessage).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(AppCopy.text("common.test")) { Task { await runTest() } }
                        .disabled(!isValid)
                    Button(AppCopy.text("composer.add")) { add() }
                        .disabled(!isValid)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (transport == .http ? !url.isEmpty : !command.isEmpty)
    }

    private func draft() -> MCPServerConfig {
        MCPServerConfig(
            name: name.trimmingCharacters(in: .whitespaces),
            transport: transport,
            url: url.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            arguments: argumentsText.split(separator: " ").map(String.init),
            enabled: true,
            autoRunReadOnly: autoRunReadOnly
        )
    }

    private func runTest() async {
        testMessage = AppCopy.text("mcp.testing")
        let result = await registry.test(draft())
        if let count = result.toolCount {
            testMessage = AppCopy.format("mcp.test.connected", count)
        } else {
            testMessage = result.error ?? AppCopy.text("mcp.test.failed")
        }
    }

    private func add() {
        registry.upsert(draft(), token: token.isEmpty ? nil : token)
        let id = registry.servers.last?.id
        name = ""; url = ""; command = ""; argumentsText = ""; token = ""
        autoRunReadOnly = false
        testMessage = nil
        if let id { Task { await registry.connect(id) } }
    }

    private func stateText(_ state: MCPRegistry.ServerState) -> String {
        switch state {
        case .idle: return AppCopy.text("common.idle")
        case .connecting: return AppCopy.text("mcp.state.connecting")
        case .connected(let count): return AppCopy.format("mcp.state.connected", count)
        case .failed(let message): return AppCopy.format("mcp.state.failed", message)
        case .needsAuthorization: return AppCopy.text("mcp.state.signIn")
        }
    }

    private func stateColor(_ state: MCPRegistry.ServerState) -> Color {
        switch state {
        case .connected: return .green
        case .failed: return .red
        case .needsAuthorization: return .orange
        default: return .secondary
        }
    }
}

/// Presents server-initiated MCP requests (sampling, elicitation) one at a
/// time. Nothing reaches a model or the server until the user answers.
struct MCPInteractionPresenter: ViewModifier {
    @ObservedObject var registry: MCPRegistry

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { registry.interactions.first },
            set: { if $0 == nil, let first = registry.interactions.first { registry.answer(first.id, .cancel) } }
        )) { interaction in
            MCPInteractionSheet(interaction: interaction) { registry.answer(interaction.id, $0) }
        }
    }
}

private struct MCPInteractionSheet: View {
    let interaction: MCPRegistry.Interaction
    let answer: (MCPRegistry.InteractionAnswer) -> Void
    @State private var values: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]

    private var params: JSONValue { interaction.params }
    private var properties: [(key: String, schema: JSONValue)] {
        (params["requestedSchema"]?["properties"]?.object ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    private var required: Set<String> {
        Set((params["requestedSchema"]?["required"]?.array ?? []).compactMap(\.string))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch interaction.kind {
            case .sampling:
                Text(AppCopy.format("mcp.sampling.title", interaction.serverName)).font(.headline)
                Text(AppCopy.text("mcp.sampling.message"))
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(samplingPreview).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 280)
                HStack {
                    Spacer()
                    Button(AppCopy.text("mcp.deny"), role: .cancel) { answer(.decline) }
                    Button(AppCopy.text("mcp.approve")) { answer(.approve) }.keyboardShortcut(.defaultAction)
                }
            case .elicitation:
                Text(AppCopy.format("mcp.elicitation.title", interaction.serverName)).font(.headline)
                Text(params["message"]?.string ?? "").font(.callout)
                Form {
                    ForEach(properties, id: \.key) { property in
                        field(property.key, property.schema)
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Button(AppCopy.text("common.cancel"), role: .cancel) { answer(.cancel) }
                    Spacer()
                    Button(AppCopy.text("mcp.decline")) { answer(.decline) }
                    Button(AppCopy.text("mcp.submit")) { answer(.accept(collected)) }

                        .keyboardShortcut(.defaultAction)
                        .disabled(!required.allSatisfy { key in flags[key] != nil || !(values[key] ?? "").isEmpty })
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func field(_ key: String, _ schema: JSONValue) -> some View {
        let title = (schema["title"]?.string ?? key) + (required.contains(key) ? " *" : "")
        if schema["type"]?.string == "boolean" {
            Toggle(title, isOn: Binding(get: { flags[key] ?? schema["default"]?.bool ?? false }, set: { flags[key] = $0 }))
        } else if let options = schema["enum"]?.array?.compactMap(\.string), !options.isEmpty {
            let names = schema["enumNames"]?.array?.compactMap(\.string) ?? options
            Picker(title, selection: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })) {
                Text("—").tag("")
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Text(index < names.count ? names[index] : option).tag(option)
                }
            }
        } else {
            TextField(title, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }),
                      prompt: schema["description"]?.string.map(Text.init))
        }
    }

    /// Typed per the requested schema; numbers that do not parse are dropped.
    private var collected: [String: JSONValue] {
        var result: [String: JSONValue] = flags.mapValues(JSONValue.bool)
        for property in properties {
            guard let raw = values[property.key], !raw.isEmpty else { continue }
            switch property.schema["type"]?.string {
            case "number", "integer": if let number = Double(raw) { result[property.key] = .number(number) }
            default: result[property.key] = .string(raw)
            }
        }
        return result
    }

    private var samplingPreview: String {
        var lines: [String] = []
        if let system = params["systemPrompt"]?.string, !system.isEmpty { lines.append("system: \(system)") }
        for message in params["messages"]?.array ?? [] {
            let content = message["content"]
            let text = content?["text"]?.string ?? "[\(content?["type"]?.string ?? "content")]"
            lines.append("\(message["role"]?.string ?? "user"): \(text)")
        }
        if let maxTokens = params["maxTokens"]?.int { lines.append("max tokens: \(maxTokens)") }
        return lines.joined(separator: "\n\n")
    }
}
