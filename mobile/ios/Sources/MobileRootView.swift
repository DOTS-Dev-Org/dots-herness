import SwiftUI
import UIKit
import WebKit
import Foundation

struct MobileRootView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var localization: MobileLocalization
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var showingSplash = true
    @StateObject private var legal = LegalModel()
    var body: some View {
        Group {
            if showingSplash {
                SplashView()
                    .transition(.opacity)
            } else if !hasSeenIntro {
                ZStack {
                    Color.black
                    IntroView { hasSeenIntro = true }
                }
                .ignoresSafeArea()
            } else if legal.needsAcceptance {
                LegalGateView(legal: legal)
            } else {
                // The on-device runtime is the default. Pairing remains a
                // backwards-compatible deep link, never an app-start gate.
                WorkspaceView()
                    .environmentObject(legal)
            }
        }
        .environment(\.locale, localization.locale)
        .environment(\.layoutDirection, localization.isRTL ? .rightToLeft : .leftToRight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.2)) { showingSplash = false }
        }
        .task {
            legal.setLanguage(localization.effective)
            await legal.load()
        }
        .onChange(of: localization.effective) { _, language in
            legal.setLanguage(language)
            Task { await legal.load() }
        }
        .alert(localization.text("mobile.connection.title"), isPresented: .constant(client.errorMessage != nil), actions: { Button(localization.text("app.ok")) { client.errorMessage = nil } }, message: { Text(client.errorMessage ?? "") })
    }
}

private struct SplashView: View {
    @EnvironmentObject private var localization: MobileLocalization

    var body: some View {
        ZStack {
            Color("SplashBackground")
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image("HerNessLogo")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 184, height: 184)
                    .accessibilityLabel(localization.text("mobile.splash.logo"))

                Text("HerNess")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .tracking(-0.6)
                    .foregroundStyle(Color(red: 0.15, green: 0.11, blue: 0.08))

                Text(localization.text("mobile.splash.buildLine"))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.black.opacity(0.52))
            }
        }
        .preferredColorScheme(.light)
        .accessibilityElement(children: .combine)
    }
}

private struct IntroSlide: Identifiable {
    let id: String
    let imageName: String
    let eyebrowKey: String
    let titleKey: String
    let descriptionKey: String
}

private let introSlides = [
    IntroSlide(id: "connect", imageName: "IntroConnect", eyebrowKey: "intro.eyebrow.connect", titleKey: "intro.title.connect", descriptionKey: "intro.description.connect"),
    IntroSlide(id: "agent", imageName: "IntroAgent", eyebrowKey: "intro.eyebrow.agent", titleKey: "intro.title.agent", descriptionKey: "intro.description.agent"),
    IntroSlide(id: "ship", imageName: "IntroShip", eyebrowKey: "intro.eyebrow.ship", titleKey: "intro.title.ship", descriptionKey: "intro.description.ship")
]

private struct IntroView: View {
    let onFinish: () -> Void
    @State private var page = 0

    var body: some View {
        ZStack {
            Color.black
            IntroSlideView(slide: introSlides[page], page: $page, onFinish: onFinish)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -50, page < introSlides.count - 1 {
                        withAnimation(.easeInOut) { page += 1 }
                    } else if value.translation.width > 50, page > 0 {
                        withAnimation(.easeInOut) { page -= 1 }
                    }
                }
        )
        .preferredColorScheme(.dark)
    }
}

private struct IntroSlideView: View {
    @EnvironmentObject private var localization: MobileLocalization
    let slide: IntroSlide
    @Binding var page: Int
    let onFinish: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image(uiImage: UIImage(named: slide.imageName) ?? UIImage())
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.08), .black.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("HerNess")
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        if localization.isRTL {
                            if page < introSlides.count - 1 {
                                Button(localization.text("intro.skip"), action: onFinish)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            MobileLanguagePicker(darkAppearance: true)
                        } else {
                            MobileLanguagePicker(darkAppearance: true)
                            if page < introSlides.count - 1 {
                                Button(localization.text("intro.skip"), action: onFinish)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }

                    Spacer()

                    Text(localization.text(slide.eyebrowKey))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.68))
                    Text(localization.text(slide.titleKey))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                    Text(localization.text(slide.descriptionKey))
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.76))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    HStack(spacing: 8) {
                        ForEach(introSlides.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == page ? .white : .white.opacity(0.3))
                                .frame(width: index == page ? 26 : 8, height: 8)
                        }
                    }
                    .padding(.top, 24)
                    .accessibilityLabel(localization.format("intro.page", page + 1, introSlides.count))

                    HStack(spacing: 8) {
                        if localization.isRTL {
                            primaryButton
                            if page > 0 { backButton }
                        } else {
                            if page > 0 { backButton }
                            primaryButton
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }
                .padding(.horizontal, 24)
                // IntroView intentionally draws edge-to-edge for the artwork;
                // keep the header below the Dynamic Island/status area even
                // when the parent has opted out of safe-area clipping.
                .padding(.top, max(geometry.safeAreaInsets.top, 54) + 12)
                .padding(.bottom, geometry.safeAreaInsets.bottom + 18)
            }
        }
    }

    private var primaryButton: some View {
        Button {
            if page == introSlides.count - 1 {
                onFinish()
            } else {
                withAnimation(.easeInOut) { page += 1 }
            }
        } label: {
            HStack(spacing: 8) {
                Text(page == introSlides.count - 1 ? localization.text("intro.start") : localization.text("intro.continue"))
                Image(systemName: localization.isRTL ? "arrow.left" : "arrow.right")
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 58)
        .background(.white)
        .foregroundStyle(.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var backButton: some View {
        Button {
            withAnimation(.easeInOut) { page -= 1 }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: localization.isRTL ? "arrow.right" : "arrow.left")
                    .font(.system(size: 14, weight: .bold))
                Text(localization.text("intro.back"))
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
        }
        .foregroundStyle(.white)
        .background(.white.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var localization: MobileLocalization
    @AppStorage("confirmBeforeExit") private var confirmBeforeExit = true
    @State private var selected: WorkspaceFile?
    @State private var editor = ""
    @State private var prompt = ""
    @State private var showingSettings = false
    @State private var showingPreview = false
    @State private var previewURL = ""
    @State private var showingExitConfirmation = false

    var files: [WorkspaceFile] { local.snapshot?.files.sorted { $0.path < $1.path } ?? client.snapshot?.files.sorted { $0.path < $1.path } ?? local.files() }

    var body: some View {
        VStack(spacing: 0) {
            if let sandbox = local.activeSandbox {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.white)
                    Text(localization.format("mobile.workspace.sandboxLabel", sandbox.name)).font(.footnote.bold()).foregroundStyle(.white)
                    Spacer()
                    Text(sandbox.branch).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.9))
            }
            TabView {
                NavigationSplitView {
                    List(files, selection: $selected) { file in
                        Label(file.path, systemImage: file.path.contains("/") ? "doc.text" : "folder")
                            .tag(file as WorkspaceFile?)
                    }
                    .navigationTitle(local.activeSandbox.map { "\(localization.text("conversation.files")) — \(localization.text("settings.sandbox")) \($0.name)" } ?? localization.text("conversation.files"))
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { if client.isPaired { await client.requestSnapshot(); if let value = client.snapshot { await local.importSnapshot(value, read: client.readFileData) } } else { local.refresh() } } } label: { Image(systemName: "arrow.clockwise") } } }
                } detail: {
                    EditorView(file: selected, editor: $editor)
                }
                .tabItem { Label(localization.text("mobile.nav.code"), systemImage: "chevron.left.forwardslash.chevron.right") }

                AgentTab(prompt: $prompt)
                    .tabItem { Label(localization.text("mobile.nav.agent"), systemImage: "sparkles") }

                TerminalTab()
                    .tabItem { Label(localization.text("mobile.nav.terminal"), systemImage: "terminal") }

                PreviewTab(url: $previewURL)
                    .tabItem { Label(localization.text("mobile.nav.preview"), systemImage: "globe") }

                SettingsView(previewURL: $previewURL, confirmBeforeExit: $confirmBeforeExit, onExit: requestExit)
                    .tabItem { Label(localization.text("mobile.nav.settings"), systemImage: "gearshape") }
            }
        }
        // Only ask the desktop for a snapshot when there is a desktop; offline the
        // mirror (a GitHub clone or the last snapshot) is already the workspace.
        .onAppear { guard client.isPaired else { return }; Task { await client.requestSnapshot(); if let value = client.snapshot { await local.importSnapshot(value, read: client.readFileData) } } }
        .onChange(of: selected) { _, file in
            guard let file else { return }
            Task { editor = local.text(for: file.path); if editor.isEmpty && client.isPaired { editor = (try? await client.readFile(file.path)) ?? "" }; local.select(file) }
        }
        .alert(localization.text("mobile.exit.title"), isPresented: $showingExitConfirmation) {
            Button(localization.text("mobile.exit.rememberAndExit"), role: .destructive) {
                confirmBeforeExit = false
                closeApp()
            }
            Button(localization.text("mobile.exit.action"), role: .destructive, action: closeApp)
            Button(localization.text("mobile.exit.cancel"), role: .cancel) { }
        } message: {
            Text(localization.text("mobile.exit.message"))
        }
    }

    private func requestExit() {
        if confirmBeforeExit {
            showingExitConfirmation = true
        } else {
            closeApp()
        }
    }

    @MainActor
    private func closeApp() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
    }
}

struct EditorView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var localization: MobileLocalization
    let file: WorkspaceFile?
    @Binding var editor: String
    @State private var saved = false
    @State private var conflict = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(file?.path ?? localization.text("mobile.workspace.selectFile")).font(.headline); Spacer(); Button(localization.text("mobile.workspace.save")) { Task { await save() } }.disabled(file == nil) }.padding()
            Divider()
            TextEditor(text: $editor).font(.system(.body, design: .monospaced)).lineSpacing(3).padding(8).accessibilityLabel(localization.text("mobile.workspace.codeEditor"))
            if saved { Text(localization.text("mobile.workspace.saved")).font(.footnote).foregroundStyle(.green).padding(.horizontal) }
        }.alert(localization.text("mobile.workspace.conflict"), isPresented: $conflict) { Button(localization.text("mobile.workspace.keepLocalEdit"), role: .cancel) { } } message: { Text(localization.text("mobile.workspace.conflictMessage")) }
    }

    private func save() async {
        guard let file else { return }
        var remoteConflict = false
        if client.bootstrap != nil {
            do {
                let response = try await client.command(kind: "write_file", payload: ["path": .string(file.path), "content": .string(editor), "expectedSha256": .string(file.sha256)], expectedRevision: client.snapshot?.revision)
                remoteConflict = response.status == "conflict"
            } catch {
                // A disconnected desktop must not prevent a local mirror save.
            }
        }
        do {
            local.select(path: file.path); local.updateCurrentText(editor); try local.saveCurrent()
            if remoteConflict { conflict = true } else { saved = true }
        } catch { client.errorMessage = error.localizedDescription }
    }

}

struct EventFeedView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var localization: MobileLocalization
    @Binding var prompt: String
    @State private var artifactText = ""
    @State private var showingArtifact = false
    @State private var artifactURL: URL?
    @State private var questionAnswer = ""
    var body: some View {
        NavigationStack {
            VStack {
                List(client.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(eventTitle(event)).font(.caption.bold()).foregroundStyle(.tint)
                        Text(eventDescription(event)).font(.system(.body, design: .monospaced)).lineLimit(8)
                        if event.kind == "approval.required", let approvalID = event.payload["approvalId"]?.string {
                            HStack {
                                Button(localization.text("permission.allowOnce")) { Task { try? await client.command(kind: "approve", payload: ["approvalId": .string(approvalID), "answer": .string("allowed-once")]) } }
                                Button(localization.text("permission.reject"), role: .destructive) { Task { try? await client.command(kind: "approve", payload: ["approvalId": .string(approvalID), "answer": .string("rejected")]) } }
                            }
                        }
                        if event.kind == "question.required", let questionID = event.payload["questionId"]?.string {
                            Text(localization.text("mobile.agent.clarification")).font(.headline)
                            Text(event.payload["questions"]?.string ?? localization.text("mobile.agent.answer")).font(.caption).foregroundStyle(.secondary)
                            TextField(localization.text("mobile.agent.answer"), text: $questionAnswer)
                            Button(localization.text("mobile.agent.answer")) {
                                let answer = questionAnswer
                                questionAnswer = ""
                                Task { try? await client.command(kind: "question", payload: ["questionId": .string(questionID), "answers": .array([.string(answer)])]) }
                            }.disabled(questionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let artifactID = event.artifactId {
                            if event.kind == "artifact.ready" {
                                let path = event.payload["path"]?.string ?? "artifact.bin"
                                Button(localization.text("common.download")) {
                                    Task {
                                        if let data = try? await client.artifactData(artifactID) {
                                            let name = URL(fileURLWithPath: path).lastPathComponent
                                            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                                            try? data.write(to: url, options: .atomic)
                                            artifactURL = url
                                        }
                                    }
                                }
                                if path.lowercased().hasSuffix(".ipa") { Text(localization.text("mobile.artifact.ipaHint")).font(.caption).foregroundStyle(.secondary) }
                            } else {
                                Button(localization.text("mobile.artifact.openOutput")) { Task { if let value = try? await client.artifactText(artifactID) { artifactText = value; showingArtifact = true } } }
                            }
                        }
                    }
                }
                HStack { TextField(localization.text("mobile.agent.ask") + "…", text: $prompt, axis: .vertical).textFieldStyle(.roundedBorder); Button(localization.text("mobile.agent.send")) { let value = prompt; prompt = ""; Task { try? await client.command(kind: "prompt", payload: ["text": .string(value), "mode": .string("queue")]) } }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding()
                if let artifactURL { ShareLink(item: artifactURL, preview: SharePreview(artifactURL.lastPathComponent)) { Label(localization.text("mobile.artifact.share"), systemImage: "square.and.arrow.up") }.padding(.bottom, 6) }
            }.navigationTitle(localization.text("mobile.agent.phone")).sheet(isPresented: $showingArtifact) { NavigationStack { TextEditor(text: $artifactText).font(.system(.body, design: .monospaced)).padding().navigationTitle(localization.text("mobile.artifact.fullOutput")).navigationBarTitleDisplayMode(.inline) } }
        }
    }

    private func eventTitle(_ event: ControlEvent) -> String {
        switch event.kind {
        case "file.changed", "file.deleted": return localization.text("mobile.event.fileOperation")
        case "run.summary": return localization.text("mobile.event.runSummary")
        case "connection.changed": return localization.text("mobile.event.connectionChanged")
        default: return event.kind
        }
    }

    private func localizedFileOperation(_ raw: String?, kind: String) -> String {
        switch (raw ?? (kind == "file.deleted" ? "removed" : "changed")).lowercased() {
        case "added": return localization.text("mobile.event.added")
        case "modified", "changed": return localization.text("mobile.event.changed")
        case "deleted", "removed": return localization.text("mobile.event.removed")
        default: return raw ?? localization.text("mobile.event.changed")
        }
    }

    private func eventDescription(_ event: ControlEvent) -> String {
        let payload = event.payload
        switch event.kind {
        case "file.changed", "file.deleted":
            let operation = localizedFileOperation(payload["operation"]?.string, kind: event.kind)
            return localization.format("mobile.event.fileDetail", operation, payload["path"]?.string ?? localization.text("mobile.event.workspaceFile"))
        case "run.summary":
            return localization.format(
                "mobile.event.runDetail",
                payload["addedCount"]?.string ?? "0",
                payload["modifiedCount"]?.string ?? "0",
                payload["deletedCount"]?.string ?? "0",
                payload["cleanupNote"]?.string ?? localization.text("mobile.event.runFinished"))
        case "connection.changed":
            let previous = payload["previousConnectionLabel"]?.string ?? localization.text("mobile.event.previousConnection")
            let current = payload["currentConnectionLabel"]?.string ?? localization.text("mobile.event.currentConnection")
            switch payload["cleanupStatus"]?.string {
            case "verified":
                return localization.format("mobile.event.connectionVerified", previous)
            case "failed":
                return localization.format("mobile.event.connectionFailed", previous)
            case "preserved":
                return localization.format("mobile.event.connectionPreserved", previous, current)
            default:
                return localization.format("mobile.event.connectionDefault", previous, current)
            }
        default:
            return (payload["warning"]?.string.map { "⚠️ \($0)\n" } ?? "") + (payload["text"]?.string ?? payload["preview"]?.string ?? payload["output"]?.string ?? localization.text("mobile.event.live"))
        }
    }
}

struct PreviewTab: View {
    @EnvironmentObject private var localization: MobileLocalization
    @Binding var url: String
    var body: some View { NavigationStack { VStack { TextField("https://project.pages.dev", text: $url).textInputAutocapitalization(.never).keyboardType(.URL).textFieldStyle(.roundedBorder).padding(); if let target = URL(string: url), !url.isEmpty { WebPreview(url: target) } else { ContentUnavailableView(localization.text("mobile.preview.none"), systemImage: "globe", description: Text(localization.text("mobile.preview.description"))) } }.navigationTitle(localization.text("mobile.preview.title")) } }
}

struct WebPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { WKWebView(frame: .zero) }
    func updateUIView(_ view: WKWebView, context: Context) { view.load(URLRequest(url: url)) }
}

struct SettingsView: View {
    @EnvironmentObject private var client: RemoteControlClient
    @EnvironmentObject private var localization: MobileLocalization
    @EnvironmentObject private var agent: MobileAgent
    @EnvironmentObject private var github: GitHubOAuth
    @EnvironmentObject private var chatGPT: ChatGPTOAuth
    @Binding var previewURL: String
    @Binding var confirmBeforeExit: Bool
    let onExit: () -> Void
    @State private var providerKey = ""
    @State private var githubOwner = ""
    @State private var githubRepository = ""
    @State private var githubBase = "main"
    @State private var githubBranch = "herness/mobile-\(Int(Date().timeIntervalSince1970))"
    @State private var githubStatus = ""
    @State private var repoSlug = ""
    @State private var repositories: [GitHubRepository] = []
    @State private var branches: [String] = []
    @State private var sandboxName = ""
    @EnvironmentObject private var local: LocalWorkspaceStore
    @EnvironmentObject private var legal: LegalModel

    var body: some View {
        NavigationStack {
            Form {
                Section(localization.text("mobile.exit.settingsSection")) {
                    Toggle(localization.text("mobile.exit.askBeforeExit"), isOn: $confirmBeforeExit)
                    Text(localization.text("mobile.exit.settingsHint"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(localization.text("mobile.exit.actionLabel"), role: .destructive, action: onExit)
                }
                Section(localization.text("intro.language")) {
                    HStack {
                        Text(localization.selected == .system ? localization.text("intro.languageSystem") : localization.selected.nativeName)
                        Spacer()
                        MobileLanguagePicker()
                    }
                }
                Section {
                    NavigationLink(localization.text("legal.title")) {
                        LegalSettingsView(legal: legal)
                    }
                }
                Section(localization.text("settings.tab.providers")) {
                    Picker(localization.text("router.provider"), selection: Binding(get: { agent.provider }, set: { agent.setProvider($0) })) {
                        Text("Anthropic").tag("anthropic")
                        Text("OpenAI").tag("openai")
                        Text("OpenAI Responses").tag("openai-responses")
                        Text("GPT / ChatGPT").tag("gpt")
                    }
                    Picker(localization.text("modelPicker.model"), selection: Binding(get: { agent.model }, set: { agent.setModel($0) })) {
                        ForEach(MobileAgent.models, id: \.self) { Text($0).tag($0) }
                    }
                    Text(localization.text("mobile.settings.providerKeyHint"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(localization.text("mobile.settings.phoneAccounts")) {
                    SecureField(localization.text("mobile.settings.providerKey"), text: $providerKey)
                    Button(localization.text("mobile.settings.saveProviderKey")) { client.savePhoneSecret(providerKey, key: "provider") }
                    Text(localization.text("mobile.settings.providerKeyHint")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(localization.text("mobile.settings.gptAccount")) {
                    if chatGPT.accessToken.isEmpty {
                        Button(chatGPT.isSigningIn ? localization.text("mobile.settings.waitingChatGPT") : localization.text("mobile.settings.signInChatGPT")) { chatGPT.start() }.disabled(chatGPT.isSigningIn)
                    } else {
                        Label("ChatGPT \(localization.text("mobile.settings.connected"))", systemImage: "checkmark.circle.fill")
                        Button(localization.text("mobile.settings.signOut"), role: .destructive) { chatGPT.signOut() }
                    }
                    if !chatGPT.status.isEmpty { Text(chatGPT.status).font(.footnote).foregroundStyle(.secondary) }
                    Text(localization.text("mobile.settings.gptHint")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(localization.text("mobile.settings.githubAccount")) {
                    if github.accessToken.isEmpty {
                        Button(github.isSigningIn ? localization.text("mobile.settings.waitingGitHub") : localization.text("mobile.settings.signInGitHub")) { github.start() }.disabled(github.isSigningIn)
                    } else {
                        Label("GitHub \(localization.text("mobile.settings.connected"))", systemImage: "checkmark.circle.fill")
                        Button(localization.text("mobile.settings.signOut"), role: .destructive) { github.signOut() }
                    }
                    if !github.status.isEmpty { Text(github.status).font(.footnote).foregroundStyle(.secondary) }
                    Text(localization.text("mobile.settings.githubHint")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(localization.text("mobile.settings.offlineRepository")) {
                    Button(localization.text("mobile.settings.loadRepositories")) { Task { await loadRepositories() } }.disabled(github.accessToken.isEmpty)
                    if !repositories.isEmpty {
                        Picker(localization.text("mobile.settings.repository"), selection: $repoSlug) {
                            Text(localization.text("mobile.settings.chooseRepository")).tag("")
                            ForEach(repositories) { Text($0.fullName).tag($0.fullName) }
                        }
                    } else {
                        TextField(localization.text("mobile.settings.ownerRepository"), text: $repoSlug).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if !branches.isEmpty {
                        Picker(localization.text("mobile.settings.branch"), selection: $githubBase) { ForEach(branches, id: \.self) { Text($0).tag($0) } }
                    } else {
                        TextField(localization.text("mobile.settings.branch"), text: $githubBase).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button(localization.text("mobile.settings.clone")) { Task { await clone() } }.disabled(github.accessToken.isEmpty || repoSlug.isEmpty)
                    if !local.cloneStatus.isEmpty { Text(local.cloneStatus).font(.footnote).foregroundStyle(.secondary) }
                    Text(localization.text("mobile.settings.selectedBranchHint")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(localization.text("settings.sandbox")) {
                    if let active = local.activeSandbox {
                        Label("\(localization.text("settings.sandboxOn")): \(active.name)", systemImage: "shippingbox.fill").foregroundStyle(.green)
                        Text("\(localization.text("settings.sandboxBranch")): \(active.branch)").font(.caption).foregroundStyle(.secondary)
                        Text(localization.text("settings.sandboxOn")).font(.footnote).foregroundStyle(.secondary)
                        if let notice = local.sandboxNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                        Button(localization.text("settings.sandboxMerge")) {
                            do { _ = try local.exitSandbox(merge: true) } catch { local.localError = error.localizedDescription }
                        }
                        Button(localization.text("settings.sandboxDiscard"), role: .destructive) {
                            do { _ = try local.exitSandbox(merge: false) } catch { local.localError = error.localizedDescription }
                        }
                        if let err = local.localError { Text(err).font(.footnote).foregroundStyle(.red) }
                    } else {
                        TextField(localization.text("settings.sandboxName"), text: $sandboxName).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(localization.text("settings.sandboxEnter")) {
                            do { try local.enterSandbox(name: sandboxName); sandboxName = "" } catch { local.localError = error.localizedDescription }
                        }.disabled(sandboxName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let notice = local.sandboxNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                        let others = local.sandboxes()
                        if !others.isEmpty {
                            ForEach(others, id: \.name) { sb in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(sb.name).font(.body)
                                        Text(sb.branch).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(localization.text("settings.sandboxDiscard"), role: .destructive) { do { try local.discardSandbox(sb) } catch { local.localError = error.localizedDescription } }
                                }
                            }
                        } else {
                            Text(localization.text("settings.sandboxOff")).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let err = local.localError { Text(err).font(.footnote).foregroundStyle(.red) }
                        Text(localization.text("settings.sandboxOrigin")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section(localization.text("mobile.settings.remoteRunner")) {
                    if client.isPaired {
                        Label(localization.text("mobile.settings.desktopPaired"), systemImage: "desktopcomputer").foregroundStyle(.green)
                        Text(localization.text("mobile.settings.remoteRunnerHint")).font(.footnote).foregroundStyle(.secondary)
                        if let caps = client.bootstrap?.capabilities.joined(separator: ", "), !caps.isEmpty { Text("Capabilities: \(caps)").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Label(localization.text("mobile.settings.noDesktop"), systemImage: "wifi.slash").foregroundStyle(.orange)
                        Text(localization.text("mobile.settings.remoteRunnerHint")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(localization.text("mobile.settings.accessModeHint")).font(.caption).foregroundStyle(.secondary)
                }
                Section(localization.text("mobile.settings.githubChanges")) {
                    TextField(localization.text("mobile.settings.owner"), text: $githubOwner).textInputAutocapitalization(.never)
                    TextField(localization.text("mobile.settings.repository"), text: $githubRepository).textInputAutocapitalization(.never)
                    TextField(localization.text("mobile.settings.baseBranch"), text: $githubBase).textInputAutocapitalization(.never)
                    TextField(localization.text("mobile.settings.newBranch"), text: $githubBranch).textInputAutocapitalization(.never)
                    Button(localization.text("mobile.settings.commitPR")) { Task { await createPullRequest() } }.disabled(github.accessToken.isEmpty || githubOwner.isEmpty || githubRepository.isEmpty)
                    if !githubStatus.isEmpty { Text(githubStatus).font(.footnote).foregroundStyle(.secondary) }
                }
                LoopsView()
                MCPSettingsView()
                PluginsView()
                Section(localization.text("mobile.settings.preview")) { TextField(localization.text("mobile.settings.pagesURL"), text: $previewURL).textInputAutocapitalization(.never) }
                Section(localization.text("mobile.settings.snapshotExclusions")) { ForEach(client.snapshot?.excluded ?? []) { item in VStack(alignment: .leading) { Text(item.path); Text(item.reason).font(.caption).foregroundStyle(.secondary) } } }
            }.navigationTitle(localization.text("settings.title")).onAppear {
                providerKey = client.phoneSecret("provider")
                let repo = RepoCoordinates.load()
                if repo.isComplete { repoSlug = repo.slug; githubOwner = repo.owner; githubRepository = repo.repository; githubBase = repo.branch }
                if !github.accessToken.isEmpty { Task { await loadRepositories() } }
            }
        }
    }

    private func clone() async {
        guard let repo = RepoCoordinates.parse(repoSlug, branch: githubBase.isEmpty ? "main" : githubBase) else {
            local.localError = localization.text("mobile.settings.repositoryInputError")
            return
        }
        githubOwner = repo.owner; githubRepository = repo.repository
        agent.selectRepository(repo)
        await local.clone(repo, token: github.accessToken, git: MobileGitClient(root: local.root, token: { SecureStore().read("oauth.github.access") ?? "" }))
    }

    private func loadRepositories() async {
        do {
            repositories = try await GitHubClient(token: github.accessToken).repositories()
            if let selected = repositories.first(where: { $0.fullName == repoSlug }) {
                repoSlug = selected.fullName; githubOwner = selected.owner; githubRepository = selected.name; githubBase = selected.defaultBranch
                branches = try await GitHubClient(token: github.accessToken).branches(owner: selected.owner, repository: selected.name)
            }
        } catch { githubStatus = error.localizedDescription }
    }

    private func createPullRequest() async {
        let changes = local.githubChanges()
        guard !changes.isEmpty else { githubStatus = localization.text("mobile.settings.noLocalChanges"); return }
        let branch = githubBranch.isEmpty ? "herness/mobile-\(Int(Date().timeIntervalSince1970))" : githubBranch
        do {
            let url = try await GitHubClient(token: github.accessToken).commitAndOpenPullRequest(owner: githubOwner, repository: githubRepository, base: githubBase, branch: branch, message: "Update from HerNess mobile", changes: changes, title: "HerNess mobile changes", body: "Created from the HerNess offline workspace mirror.")
            githubStatus = url.absoluteString
        } catch { githubStatus = error.localizedDescription }
    }
}
