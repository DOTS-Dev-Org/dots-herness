// Copyright (c) 2026 DOTS
// Add, test, and toggle MCP servers whose tools the agent can call.

import SwiftUI
import DotsHarnessCore

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
            Section("Servers") {
                if registry.servers.isEmpty {
                    Text("No MCP servers configured.").foregroundStyle(.secondary)
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
                        Button("Reconnect") { Task { await registry.connect(status.id) } }
                        Button("Remove", role: .destructive) { registry.remove(status.id) }
                    }
                }
            }

            Section("Add server") {
                TextField("Name", text: $name)
                Picker("Transport", selection: $transport) {
                    Text("HTTP").tag(MCPTransportKind.http)
                    Text("stdio").tag(MCPTransportKind.stdio)
                }
                if transport == .http {
                    TextField("URL", text: $url)
                    SecureField("Bearer token (optional)", text: $token)
                } else {
                    TextField("Executable path", text: $command)
                    TextField("Arguments (space-separated)", text: $argumentsText)
                }
                Toggle("Auto-run tools the server marks read-only", isOn: $autoRunReadOnly)

                if let testMessage {
                    Text(testMessage).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Test") { Task { await runTest() } }
                        .disabled(!isValid)
                    Button("Add") { add() }
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
        testMessage = "Testing…"
        let result = await registry.test(draft())
        if let count = result.toolCount {
            testMessage = "Connected. \(count) tool(s) available."
        } else {
            testMessage = result.error ?? "Connection failed."
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
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected(let count): return "Connected · \(count) tool(s)"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private func stateColor(_ state: MCPRegistry.ServerState) -> Color {
        switch state {
        case .connected: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
