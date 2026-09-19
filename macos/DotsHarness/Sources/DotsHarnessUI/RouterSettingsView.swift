// Copyright (c) 2026 DOTS
// Native provider accounts and sharing surfaces.

import AppKit
import SwiftUI
import DotsHarnessCore

struct RouterProvidersView: View {
    @ObservedObject var router: RouterController
    @State private var isProviderPickerPresented = false
    @State private var isAPIKeyVisible = false
    @FocusState private var isAPIKeyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = router.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            Form {
                Section(AppCopy.text("router.addAccount")) {
                    LabeledContent(AppCopy.text("router.provider")) {
                        Button {
                            isProviderPickerPresented.toggle()
                        } label: {
                            ZStack(alignment: .leading) {
                                Text(router.selectedKind.name)
                                    .lineLimit(1)
                                    .padding(.leading, 38)
                                    .padding(.trailing, 28)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ProviderLogoView(name: router.selectedKind.name, providerID: router.selectedKind.id)
                                HStack {
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 280, height: 28, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .accessibilityValue(router.selectedKind.name)
                        .popover(isPresented: $isProviderPickerPresented, arrowEdge: .bottom) {
                            ProviderPickerPopover(
                                providers: RouterCatalog.providers,
                                selection: $router.selectedKind,
                                isPresented: $isProviderPickerPresented
                            )
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
                    let groups = RouterCatalog.groups(from: router.connections)
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        Section {
                            ForEach(group.accounts) { connection in
                                connectionRow(connection)
                            }
                            if let kind = RouterCatalog.kind(for: group.provider) {
                                HStack {
                                    Spacer(minLength: 0)
                                    Button {
                                        router.selectedKind = kind
                                        Task { await router.startConnect() }
                                    } label: {
                                        Image(systemName: "plus")
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(AppCopy.text("router.addAnotherAccount"))
                                    .accessibilityLabel(AppCopy.text("router.addAnotherAccount"))
                                    .disabled(!router.reachable || router.flow != .idle && kind.kind != .apiKey)
                                }
                            }
                        } header: {
                            providerHeader(group, order: groups.map(\.provider), index: index)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(AppCopy.text("settings.tab.providers"))
        .onChange(of: router.selectedKind.id) { _, _ in isAPIKeyVisible = false }
        .task {
            await router.refresh()
            await router.refreshModels(force: true)
            await router.refreshAccountUsage()
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
        let hint = router.selectedKind.baseURL.isEmpty ? AppCopy.text("router.customEndpointHint") : RouterCatalog.hint(for: router.selectedKind.id)
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
                Text(AppCopy.text("settings.addProviderCustom"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField(AppCopy.text("router.name"), text: $router.apiKeyName)
                LabeledContent(AppCopy.text("router.apiKey")) {
                    HStack(spacing: 6) {
                        Group {
                            if isAPIKeyVisible {
                                TextField("", text: $router.apiKeyValue)
                            } else {
                                SecureField("", text: $router.apiKeyValue)
                            }
                        }
                        .focused($isAPIKeyFocused)
                        .frame(maxWidth: .infinity)
                        Button {
                            isAPIKeyVisible.toggle()
                            isAPIKeyFocused = true
                        } label: {
                            Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(isAPIKeyVisible ? "Hide API key" : "Show API key")
                        .accessibilityLabel(isAPIKeyVisible ? "Hide API key" : "Show API key")
                    }
                }
            }
        case .oauthBrowser, .oauthDevice:
            Text(selectedAccountCount == 0
                 ? AppCopy.text("router.oauthBrowserHint")
                 : AppCopy.text("router.oauthAnotherHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .passthrough:
            Text(AppCopy.text("router.noKeyRequired"))
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
                    Text(connection.name).font(.headline)
                }
                Spacer()
                Toggle(AppCopy.text("router.active"), isOn: Binding(
                    get: { connection.active },
                    set: { _ in Task { await router.toggle(connection) } }
                ))
                .labelsHidden()
            }
            HStack(spacing: 8) {
                TagBadge(connection.status)
                TagBadge(authLabel(connection.authType))
                if let fraction = router.accountUsage[connection.id]?.remainingFraction {
                    TagBadge(AppCopy.format("router.quotaRemaining", Int((fraction * 100).rounded())))
                }
                if let email = connection.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await router.test(connection) } } label: {
                    Image(systemName: "checkmark.circle")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(AppCopy.text("common.test"))
                .accessibilityLabel(AppCopy.text("common.test"))
                Button(role: .destructive) { Task { await router.remove(connection) } } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(AppCopy.text("common.remove"))
                .accessibilityLabel(AppCopy.text("common.remove"))
            }
            Toggle(AppCopy.text("router.imageFallback"), isOn: Binding(
                get: { connection.imageFallbackEnabled },
                set: { _ in Task { await router.toggleImageFallback(connection) } }
            ))
            .font(.caption)
            if let error = connection.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func providerHeader(_ group: ProviderAccountGroup, order: [String], index: Int) -> some View {
        HStack(spacing: 8) {
            ProviderLogoView(name: group.label, providerID: group.provider)
            Text(AppCopy.format(
                "router.accountSection",
                group.label,
                group.accounts.count,
                group.accounts.count == 1 ? AppCopy.text("router.account") : AppCopy.text("router.accounts")
            ))
            .font(.headline.weight(.semibold))
            Spacer(minLength: 0)
            if order.count > 1 {
                Button {
                    router.reorderProviders(move(order, from: index, to: index - 1))
                } label: {
                    Image(systemName: "chevron.up").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help(AppCopy.text("router.priorityUp"))
                .accessibilityLabel(AppCopy.text("router.priorityUp"))
                Button {
                    router.reorderProviders(move(order, from: index, to: index + 1))
                } label: {
                    Image(systemName: "chevron.down").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(index == order.count - 1)
                .help(AppCopy.text("router.priorityDown"))
                .accessibilityLabel(AppCopy.text("router.priorityDown"))
            }
        }
        .padding(.vertical, 2)
        .draggable(group.provider) {
            Text(group.label).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first,
                  let from = order.firstIndex(of: dragged) else { return false }
            router.reorderProviders(move(order, from: from, to: index))
            return true
        }
    }

    /// Returns `order` with the element at `from` moved to `to` (clamped).
    private func move(_ order: [String], from: Int, to: Int) -> [String] {
        guard order.indices.contains(from) else { return order }
        var next = order
        let element = next.remove(at: from)
        next.insert(element, at: min(max(to, 0), next.count))
        return next
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
    let providerID: String
    @State private var imageData: Data?

    private var mark: String {
        let words = name.split(separator: " ")
        if words.count > 1 { return words.prefix(2).compactMap { $0.first }.map(String.init).joined() }
        return String(name.prefix(2)).uppercased()
    }

    private var logoURL: URL? { ProviderLogoSource.url(for: providerID) }

    var body: some View {
        Group {
            if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Text(mark)
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.black)
            }
        }
        .frame(width: 28, height: 28)
        .background(.white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        }
        .accessibilityHidden(true)
        .task(id: logoURL) {
            imageData = nil
            guard let logoURL else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: logoURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                guard NSImage(data: data) != nil else { return }
                imageData = data
            } catch {
                // Keep the readable initials fallback when the logo is offline.
            }
        }
    }
}

private enum ProviderLogoSource {
    // Brand marks come from Iconify's SVG logo collections; initials are the
    // offline fallback when a logo cannot be fetched.
    private static let icons: [String: String] = [
        "gpt": "logos:openai-icon",
        "claude": "logos:claude-icon",
        "anthropic": "logos:anthropic-icon",
        "grok-cli": "logos:grok-icon",
        "gemini-cli": "thesvg-color:gemini",
        "antigravity": "thesvg-color:antigravity-google",
        "opencode": "thesvg-color:opencode",
        "opencode-go": "thesvg-color:opencode",
        "nvidia": "logos:nvidia",
        "zai": "thesvg-color:glm-v",
        "gemini": "thesvg-color:gemini",
        "deepseek": "logos:deepseek-icon",
        "openai": "logos:openai-icon",
        "openrouter": "thesvg-color:openrouter-light",
        "qwen": "logos:qwen-icon",
        "grok": "logos:grok-icon",
        "glm": "thesvg-color:glm-v",
        "kimi": "thesvg-color:kimi",
        "minimax": "logos:minimax-icon",
        "groq": "thesvg-color:groq",
        "mistral": "logos:mistral-ai-icon",
        "perplexity": "logos:perplexity-icon",
        "together": "thesvg-color:togetherdotai",
        "fireworks": "thesvg-color:fireworks",
        "cerebras": "thesvg-color:cerebras",
        "deepinfra": "thesvg-color:deepinfra",
    ]

    static func url(for providerID: String) -> URL? {
        guard let icon = icons[providerID] else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.iconify.design"
        components.path = "/\(icon).svg"
        components.queryItems = [URLQueryItem(name: "height", value: "48")]
        return components.url
    }
}

private struct ProviderPickerPopover: View {
    let providers: [RouterProviderKind]
    @Binding var selection: RouterProviderKind
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppCopy.text("router.provider"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(providers) { kind in
                        Button {
                            selection = kind
                            isPresented = false
                        } label: {
                            HStack(spacing: 10) {
                                ProviderLogoView(name: kind.name, providerID: kind.id)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.name)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(RouterCatalog.hint(for: kind.id))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if selection.id == kind.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                selection.id == kind.id
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(kind.name)
                        .accessibilityAddTraits(selection.id == kind.id ? .isSelected : [])
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 320, height: 430)
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
        .task {
            await router.refresh()
            router.refreshShareKey()
        }
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
