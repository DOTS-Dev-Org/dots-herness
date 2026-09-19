import SwiftUI

/// Terminal commands run through the constrained on-device runtime.
struct TerminalTab: View {
    var body: some View {
        PhoneTerminalView()
    }
}

struct PhoneTerminalView: View {
    @EnvironmentObject private var shell: LocalShell
    @EnvironmentObject private var localization: MobileLocalization
    @State private var command = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(shell.lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: shell.lines.count) { _, count in
                        withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                .background(.black.opacity(0.92))
                .foregroundStyle(.green)

                HStack(spacing: 6) {
                    Text(shell.prompt).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                    TextField("ls -l", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(send)
                    Button(localization.text("mobile.terminal.run"), action: send).disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
            }
            .navigationTitle(localization.text("mobile.terminal.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(localization.text("mobile.terminal.help")) { Task { await shell.run("help") } } } }
        }
    }

    private func send() {
        let value = command
        command = ""
        Task { await shell.run(value) }
    }
}

struct PluginsView: View {
    @EnvironmentObject private var plugins: MobilePlugins
    @EnvironmentObject private var agent: MobileAgent
    @EnvironmentObject private var localization: MobileLocalization

    var body: some View {
        Section(localization.text("settings.pluginsTitle")) {
            if plugins.loaded.isEmpty && plugins.failures.isEmpty {
                Text(localization.text("mobile.plugins.emptyHint"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(plugins.loaded) { manifest in
                VStack(alignment: .leading) {
                    Text("\(manifest.name) \(manifest.version)")
                    if !manifest.description.isEmpty { Text(manifest.description).font(.caption).foregroundStyle(.secondary) }
                }
            }
            ForEach(plugins.failures.sorted(by: { $0.key < $1.key }), id: \.key) { name, message in
                VStack(alignment: .leading) {
                    Text(name).foregroundStyle(.red)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(localization.text("mobile.plugins.reload")) {
                agent.register(plugins.reload())
                agent.pluginPrompt = plugins.promptSections.joined(separator: "\n")
            }
        }
    }
}

struct MCPSettingsView: View {
    @EnvironmentObject private var mcp: MCPRegistry
    @EnvironmentObject private var agent: MobileAgent
    @EnvironmentObject private var localization: MobileLocalization
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        Section(localization.text("mobile.mcp.title")) {
            ForEach(mcp.servers) { server in
                VStack(alignment: .leading) {
                    Text(server.name)
                    Text(mcp.status[server.id] ?? server.url).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button(localization.text("common.remove"), role: .destructive) { mcp.remove(server) } }
            }
            TextField(localization.text("tasks.field.name"), text: $name).textInputAutocapitalization(.never)
            TextField("https://example.com/mcp", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            SecureField(localization.text("mobile.mcp.bearerToken"), text: $token)
            Button(localization.text("mobile.mcp.add")) {
                mcp.add(name: name, url: url, token: token)
                name = ""; url = ""; token = ""
                Task { await mcp.connectAll(into: agent) }
            }
            .disabled(url.isEmpty)
            Button(localization.text("mobile.mcp.reconnect")) { Task { await mcp.connectAll(into: agent) } }
            Text(localization.text("mobile.mcp.httpsHint"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
