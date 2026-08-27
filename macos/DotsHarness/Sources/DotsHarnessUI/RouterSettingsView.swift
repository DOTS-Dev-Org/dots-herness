// Copyright (c) 2026 DOTS
// Native provider accounts and sharing surfaces.

import AppKit
import SwiftUI
import DotsHarnessCore

struct RouterProvidersView: View {
    @ObservedObject var router: RouterController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = router.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            Form {
                Section(AppCopy.text("router.addAccount")) {
                    Picker(AppCopy.text("router.provider"), selection: $router.selectedKind) {
                        ForEach(RouterCatalog.providers) { kind in
                            HStack(spacing: 8) {
                                ProviderLogoView(name: kind.name, key: kind.logoSymbol)
                                Text(kind.name)
                            }
                            .tag(kind)
                        }
                    }
                    Text(connectHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    connectFields
                    HStack {
                        Button(connectButtonTitle) { Task { await router.startConnect() } }
                            .disabled(!router.reachable || router.flow != .idle && !isAPIKey || isAPIKey && router.selectedKind.baseURL.isEmpty)
                        if router.flow != .idle {
                            Button(AppCopy.text("common.cancel"), action: router.cancelFlow)
                        }
                    }
                }
                flowSection
                if router.connections.isEmpty {
                    Section(AppCopy.text("router.connectedAccounts")) {
                        Text(AppCopy.text("router.noConnections"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(RouterCatalog.groups(from: router.connections)) { group in
                        Section(AppCopy.format(
                            "router.accountSection",
                            group.label,
                            group.accounts.count,
                            group.accounts.count == 1 ? AppCopy.text("router.account") : AppCopy.text("router.accounts")
                        )) {
                            ForEach(group.accounts) { connection in
                                connectionRow(connection)
                            }
                            Button(AppCopy.format("router.addAnotherProviderAccount", group.label)) {
                                if let kind = RouterCatalog.kind(for: group.provider) {
                                    router.selectedKind = kind
                                }
                                Task { await router.startConnect() }
                            }
                            .disabled(!router.reachable || router.flow != .idle && RouterCatalog.kind(for: group.provider)?.kind != .apiKey)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(AppCopy.text("settings.tab.providers"))
        .task {
            await router.refresh()
            await router.refreshModels(force: true)
        }
    }

    private var isAPIKey: Bool { router.selectedKind.kind == .apiKey }

    private var selectedAccountCount: Int {
        router.connections.filter { $0.provider == router.selectedKind.id }.count
    }

    private var connectButtonTitle: String {
        selectedAccountCount == 0 ? AppCopy.text("common.connect") : AppCopy.text("router.addAnotherAccount")
    }

    private var connectHint: String {
        let extra = selectedAccountCount == 0
            ? ""
            : AppCopy.format("router.connectedExtra", selectedAccountCount)
        let hint = router.selectedKind.baseURL.isEmpty ? "Custom API endpoint" : RouterCatalog.hint(for: router.selectedKind.id)
        return hint + extra
    }

    private var header: some View {
        HStack {
            Text(AppCopy.text("settings.tab.providers")).font(.title2.weight(.semibold))
            Spacer()
            Text(router.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(AppCopy.text("common.refresh")) { Task { await router.refresh() } }
        }
        .padding()
    }

    @ViewBuilder
    private var connectFields: some View {
        switch router.selectedKind.kind {
        case .apiKey:
            if router.selectedKind.baseURL.isEmpty {
                Text("Add this provider through Custom API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField(AppCopy.text("router.name"), text: $router.apiKeyName)
                SecureField(AppCopy.text("router.apiKey"), text: $router.apiKeyValue)
            }
        case .oauthBrowser, .oauthDevice:
            Text(selectedAccountCount == 0
                 ? AppCopy.text("router.oauthBrowserHint")
                 : AppCopy.text("router.oauthAnotherHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var flowSection: some View {
        switch router.flow {
        case .idle:
            EmptyView()
        case .browser(_, let authURL, _, _, _):
            Section(AppCopy.text("router.browserLogin")) {
                Text(authURL).font(.caption.monospaced()).textSelection(.enabled)
                TextField(AppCopy.text("router.callbackURL"), text: $router.callbackPaste)
                Button(AppCopy.text("router.finishLogin")) { Task { await router.finishBrowser() } }
            }
        case .device(_, let userCode, let verificationURL, _, _, _):
            Section(AppCopy.text("router.deviceLogin")) {
                if !userCode.isEmpty {
                    Text(userCode).font(.title2.monospaced()).textSelection(.enabled)
                }
                Text(verificationURL).font(.caption.monospaced()).textSelection(.enabled)
                Text(AppCopy.text("router.waitingAuthorization")).foregroundStyle(.secondary)
            }
        }
    }

    private func connectionRow(_ connection: RouterConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if let kind = RouterCatalog.kind(for: connection.provider) {
                            ProviderLogoView(name: kind.name, key: kind.logoSymbol)
                        } else {
                            ProviderLogoView(name: AppCopy.text("router.custom"), key: "generic")
                        }
                        Text(connection.name).font(.headline)
                    }
                    Text(RouterCatalog.label(for: connection.provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(AppCopy.text("router.active"), isOn: Binding(
                    get: { connection.active },
                    set: { _ in Task { await router.toggle(connection) } }
                ))
                .labelsHidden()
            }
            HStack(spacing: 8) {
                badge(connection.status)
                badge(authLabel(connection.authType))
                if let email = connection.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppCopy.text("common.test")) { Task { await router.test(connection) } }
                Button(AppCopy.text("common.remove"), role: .destructive) { Task { await router.remove(connection) } }
            }
            if let error = connection.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func authLabel(_ value: String) -> String {
        switch value {
        case "chatgpt": return "Browser sign-in"
        case "apiKey": return "API key"
        case "custom": return "Custom API"
        default: return value
        }
    }
}

private struct ProviderLogoView: View {
    let name: String
    let key: String

    private var mark: String {
        switch key {
        case "gpt": return "✳"
        case "gemini": return "✦"
        case "openai": return "◎"
        case "openrouter": return "↗"
        case "github": return "GH"
        case "iflow": return "iF"
        case "minimax": return "MM"
        case "cohere": return "Co"
        case "siliconflow": return "SF"
        case "chutes": return "Ch"
        case "generic": return "•"
        default: break
        }
        let words = name.split(separator: " ")
        if words.count > 1 { return words.prefix(2).compactMap { $0.first }.map(String.init).joined() }
        return String(name.prefix(2)).uppercased()
    }

    private var color: Color {
        switch key {
        case "gpt", "openai": return Color(red: 0.16, green: 0.47, blue: 0.34)
        case "claude", "anthropic": return Color(red: 0.84, green: 0.42, blue: 0.19)
        case "gemini": return Color(red: 0.26, green: 0.48, blue: 0.88)
        case "github": return Color(red: 0.20, green: 0.20, blue: 0.23)
        case "grok", "xai": return Color(red: 0.08, green: 0.08, blue: 0.09)
        case "deepseek": return Color(red: 0.20, green: 0.40, blue: 0.86)
        case "mistral": return Color(red: 0.88, green: 0.32, blue: 0.15)
        case "perplexity": return Color(red: 0.10, green: 0.52, blue: 0.48)
        case "nvidia": return Color(red: 0.35, green: 0.62, blue: 0.15)
        case "vertex": return Color(red: 0.25, green: 0.48, blue: 0.88)
        case "generic": return Color.secondary
        default: break
        }
        let value = abs(key.unicodeScalars.reduce(0) { ($0 * 31) + Int($1.value) })
        return Color(hue: Double(value % 360) / 360, saturation: 0.56, brightness: 0.78)
    }

    var body: some View {
        Text(mark)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(.white)
            .frame(width: 25, height: 25)
            .background(color, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(name)
    }
}

struct RouterShareView: View {
    @ObservedObject var router: RouterController

    var body: some View {
        Form {
            Section(AppCopy.text("router.cloudflareTunnel")) {
                LabeledContent(AppCopy.text("settings.status")) {
                    Text(router.tunnel.running ? AppCopy.text("router.running") : (router.tunnel.enabled ? AppCopy.text("router.enabled") : AppCopy.text("router.stopped")))
                }
                if !router.tunnel.shortId.isEmpty {
                    LabeledContent(AppCopy.text("router.shortID")) { Text(router.tunnel.shortId).textSelection(.enabled) }
                }
                if !router.tunnel.shareURL.isEmpty {
                    LabeledContent(AppCopy.text("router.publicURL")) {
                        Text(router.tunnel.shareURL).textSelection(.enabled)
                    }
                }
                if router.tunnel.downloading {
                    ProgressView(value: Double(router.tunnel.progress), total: 100) {
                        Text(AppCopy.text("router.downloadingCloudflared"))
                    }
                }
                HStack {
                    if router.tunnel.running || router.tunnel.enabled {
                        Button(AppCopy.text("router.stopSharing")) { Task { await router.disableTunnel() } }
                    } else {
                        Button(AppCopy.text("router.shareTunnel")) { Task { await router.enableTunnel() } }
                            .disabled(!router.reachable)
                    }
                    if !router.tunnel.shareURL.isEmpty {
                        Button(AppCopy.text("router.copyURL"), action: router.copyShareURL)
                    }
                }
                Text(AppCopy.text("router.tunnelHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(AppCopy.text("router.giveClient")) {
                if let key = router.keys.first(where: \.active) ?? router.keys.first {
                    LabeledContent(AppCopy.text("settings.endpoint")) {
                        Text(shareEndpoint).textSelection(.enabled)
                    }
                    LabeledContent(key.name) {
                        Text(masked(key.key)).font(.body.monospaced())
                    }
                    HStack {
                        Button(AppCopy.text("router.copyEndpoint")) { copy(shareEndpoint) }
                        Button(AppCopy.text("router.copyAPIKey")) { copy(key.key) }
                    }
                } else {
                    Text(AppCopy.text("router.noAPIKey"))
                    Button(AppCopy.text("router.createKey")) { Task { await router.createShareKey() } }
                        .disabled(!router.reachable)
                }
            }
            if let error = router.error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("settings.tab.share"))
        .task { await router.refresh() }
    }

    private var shareEndpoint: String {
        guard !router.tunnel.shareURL.isEmpty else { return "Enable sharing to create an endpoint" }
        return router.tunnel.shareURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1"
    }

    private func masked(_ key: String) -> String {
        guard key.count > 10 else { return key }
        return String(key.prefix(10)) + "…"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        router.status = AppCopy.text("common.copied")
    }
}
