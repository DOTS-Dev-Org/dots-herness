import SwiftUI

/// Terminal commands run through the constrained on-device runtime.
struct TerminalTab: View {
    let onBack: () -> Void

    var body: some View {
        PhoneTerminalView(onBack: onBack)
    }
}

struct PhoneTerminalView: View {
    @EnvironmentObject private var shell: LocalShell
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var localization: MobileLocalization
    let onBack: () -> Void
    @State private var command = ""
    @State private var useRemote = false
    @State private var remoteOutput = ""
    @State private var remoteRunning = false
    @State private var remoteMessage = ""
    @FocusState private var focused: Bool

    private var remoteAvailable: Bool {
        client.isPaired && local.selectedProject.remoteProjectID != nil
            && local.selectedProject.remoteProjectID == client.remoteSelectedProjectID
    }

    private var visibleLines: [String] {
        let text = useRemote ? remoteOutput : shell.lines.joined(separator: "\n")
        return Array(text.components(separatedBy: .newlines).suffix(600))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if remoteAvailable {
                    Picker(localization.text("mobile.terminal.runtime"), selection: $useRemote) {
                        Text(localization.text("mobile.terminal.phoneRuntime")).tag(false)
                        Text(localization.text("mobile.terminal.desktopRuntime")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }

                if useRemote {
                    HStack {
                        Label(remoteRunning ? localization.text("mobile.terminal.sessionActive") : localization.text("mobile.terminal.sessionPaused"),
                              systemImage: remoteRunning ? "dot.radiowaves.left.and.right" : "desktopcomputer")
                            .font(.caption)
                        Spacer()
                        Button(remoteRunning ? localization.text("mobile.terminal.reconnect") : localization.text("mobile.terminal.start")) {
                            Task { await startRemote() }
                        }
                        .disabled(!remoteAvailable)
                        if remoteRunning {
                            Button(localization.text("mobile.terminal.stop"), role: .destructive) { Task { await stopRemote() } }
                        }
                    }
                    .padding(.horizontal, 10)
                    if !remoteMessage.isEmpty {
                        Text(remoteMessage).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 6)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["./run.sh", "npm run dev", "npm test", "npm run build", "git status", "git diff"], id: \.self) { value in
                                Button(value) { command = value; send() }
                                    .font(.system(.caption, design: .monospaced))
                                    .buttonStyle(.bordered)
                                    .disabled(!remoteRunning)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    .padding(.bottom, 8)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(visibleLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: visibleLines.count) { _, count in
                        if count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                    }
                }
                .background(.black.opacity(0.92))
                .foregroundStyle(.green)

                HStack(spacing: 6) {
                    Text(useRemote ? "desktop ›" : shell.prompt).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: localization.isRTL ? "chevron.right" : "chevron.left")
                    }
                    .accessibilityLabel(localization.text("intro.back"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if useRemote {
                        Button("Ctrl-C") { Task { await sendRemote("\u{3}") } }.disabled(!remoteRunning)
                    } else {
                        Button(localization.text("mobile.terminal.help")) { Task { await shell.run("help") } }
                    }
                }
            }
            .task(id: useRemote && remoteAvailable) {
                guard useRemote && remoteAvailable else { return }
                await refreshRemote()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(800))
                    if Task.isCancelled { break }
                    await refreshRemote()
                }
            }
            .onChange(of: remoteAvailable) { _, available in
                if !available { useRemote = false; remoteRunning = false; remoteOutput = "" }
            }
        }
    }

    private func send() {
        let value = command
        command = ""
        if useRemote {
            Task { await sendRemote(value + "\n") }
        } else {
            Task { await shell.run(value) }
        }
    }

    private func startRemote() async {
        do {
            let response = try await client.command(kind: "terminal_session", payload: ["action": .string("start")])
            if response.status == "approval-required" {
                remoteMessage = localization.text("mobile.terminal.approvalHint")
                return
            }
            try applyTerminalResponse(response)
            remoteMessage = remoteRunning ? "" : localization.text("mobile.terminal.startFailed")
        } catch { remoteMessage = error.localizedDescription }
    }

    private func refreshRemote() async {
        do {
            let response = try await client.command(kind: "terminal_session", payload: ["action": .string("read")])
            try applyTerminalResponse(response)
        } catch { remoteMessage = error.localizedDescription }
    }

    private func sendRemote(_ input: String) async {
        do {
            let response = try await client.command(kind: "terminal_session", payload: ["action": .string("send"), "input": .string(input)])
            if response.status == "approval-required" {
                remoteMessage = localization.text("mobile.terminal.approvalHint")
                return
            }
            try applyTerminalResponse(response)
        } catch { remoteMessage = error.localizedDescription }
    }

    private func stopRemote() async {
        do {
            _ = try await client.command(kind: "terminal_session", payload: ["action": .string("stop")])
            remoteRunning = false
            remoteMessage = ""
        } catch { remoteMessage = error.localizedDescription }
    }

    private func applyTerminalResponse(_ response: CommandResponse) throws {
        if let error = response.error, !error.isEmpty { throw ClientError.server(error) }
        guard case .object(let result) = response.result else {
            if let text = response.result?.string { remoteMessage = text }
            return
        }
        remoteRunning = result["running"]?.bool ?? false
        remoteOutput = result["output"]?.string ?? ""
        if remoteRunning { remoteMessage = "" }
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
                agent.replaceProjectTools(plugins.reload())
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
