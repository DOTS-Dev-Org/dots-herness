import SwiftUI

@main
struct HerNessMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var localization = MobileLocalization()
    @StateObject private var theme = MobileTheme()
    @StateObject private var client: RemoteControlClient
    @StateObject private var workspace: LocalWorkspaceStore
    @StateObject private var shell: LocalShell
    @StateObject private var plugins: MobilePlugins
    @StateObject private var mcp = MCPRegistry()
    @StateObject private var loops: LoopScheduler
    @StateObject private var githubOAuth = GitHubOAuth()
    @StateObject private var chatGPTOAuth = ChatGPTOAuth()
    @StateObject private var agent = MobileAgent(
        apiKey: { "" },
        systemPrompt: { HerNessMobileApp.systemPrompt },
        oauthToken: { ChatGPTOAuth.accessToken(for: ChatGPTOAuth.activeAccountID()) },
        sessionAccountID: { ChatGPTQuota.shared.roomiestAccountID() },
        providerAPIKey: { provider in
            SecureStore().read(MobileAgent.credentialKey(for: provider)) ?? ""
        },
        oauthTokenForAccount: { ChatGPTOAuth.accessToken(for: $0) },
        chatGPTAccountIDs: { ChatGPTOAuth.accountIDs() })

    init() {
        let storedProvider = UserDefaults.standard.string(forKey: "herness.agent.provider") ?? "anthropic"
        let migrationProvider = MobileAgent.definition(for: storedProvider)?.requiresAPIKey == true ? storedProvider : "anthropic"
        SecureStore().migrateLegacyProviderKey(to: migrationProvider)
        let client = RemoteControlClient()
        _client = StateObject(wrappedValue: client)
        let workspace = LocalWorkspaceStore()
        _workspace = StateObject(wrappedValue: workspace)
        let plugins = MobilePlugins(store: workspace)
        let shell = LocalShell(store: workspace)
        _plugins = StateObject(wrappedValue: plugins)
        _shell = StateObject(wrappedValue: shell)
        _loops = StateObject(wrappedValue: LoopScheduler {
            // A loop gets its own agent so a scheduled run never interleaves with
            // whatever the user is typing in the Agent tab.
            let agent = MobileAgent(
                apiKey: { "" },
                systemPrompt: { Self.systemPrompt },
                oauthToken: { ChatGPTOAuth.accessToken(for: ChatGPTOAuth.activeAccountID()) },
                sessionAccountID: { ChatGPTQuota.shared.roomiestAccountID() },
                providerAPIKey: { provider in
                    SecureStore().read(MobileAgent.credentialKey(for: provider)) ?? ""
                },
                oauthTokenForAccount: { ChatGPTOAuth.accessToken(for: $0) },
                chatGPTAccountIDs: { ChatGPTOAuth.accountIDs() })
            agent.setProjectLocationAvailabilityProvider { workspace.projectLocationAvailableNow }
            agent.selectProject(workspace.selectedProjectID)
            agent.setWorkspaceSnapshotProvider { try workspace.agentFiles() }
            agent.setLearnedRulesProvider { MobileLessons.rulesText(root: workspace.root) }
            // ponytail: a scheduled run has no one to ask, so it asks no memory questions.
            agent.setPersonalMemoryProvider { hasProject in
                MobilePersonalMemory.text(
                    userRoot: MobilePersonalMemory.defaultRoot(),
                    workspace: hasProject ? workspace.root : nil
                )
            }
            let git = MobileGitClient(root: workspace.root, token: { SecureStore().read("oauth.github.access") ?? "" })
            agent.setGitClient(git)
            agent.register(AgentTools.workspace(workspace))
            agent.register(AgentTools.runtime(shell: shell, store: workspace, git: git, remote: client))
            agent.replaceProjectTools(plugins.reload())
            return agent
        })
    }

    static let systemPrompt = HerNessPrompt.phone

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(client)
                .environmentObject(localization)
                .environmentObject(theme)
                .environmentObject(workspace)
                .environmentObject(agent)
                .environmentObject(shell)
                .environmentObject(plugins)
                .environmentObject(mcp)
                .environmentObject(loops)
                .environmentObject(githubOAuth)
                .environmentObject(chatGPTOAuth)
                .environment(\.locale, localization.locale)
                .environment(\.layoutDirection, localization.isRTL ? .rightToLeft : .leftToRight)
                .preferredColorScheme(theme.isDark ? .dark : .light)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(MobileWindowBehavior())
                .modifier(AppStoreUpdatePrompt(localization: localization))
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { agent.pauseForLifecycleInterruption() }
                    if phase == .active { agent.resumeRecoveredConversationIfNeeded() }
                }
        .task {
            await chatGPTOAuth.refreshIfNeeded()
            agent.setProjectLocationAvailabilityProvider { workspace.projectLocationAvailableNow }
            agent.selectProject(workspace.selectedProjectID)
            shell.resetForProject()
            agent.setWorkspaceSnapshotProvider { try workspace.agentFiles() }
            agent.setLearnedRulesProvider { MobileLessons.rulesText(root: workspace.root) }
            agent.setMemoryQuestions(
                provider: { asked in MobileLessons.memoryQuestions(root: workspace.root, asked: asked, text: localization.text) },
                answer: { id, choice in MobileLessons.answerMemoryQuestion(id, choice: choice, root: workspace.root) }
            )
            agent.setPersonalMemoryProvider { hasProject in
                MobilePersonalMemory.text(
                    userRoot: MobilePersonalMemory.defaultRoot(),
                    workspace: hasProject ? workspace.root : nil
                )
            }
            let git = MobileGitClient(root: workspace.root, token: { SecureStore().read("oauth.github.access") ?? "" })
            agent.setGitClient(git)
            agent.register(AgentTools.workspace(workspace))
            agent.register(AgentTools.runtime(shell: shell, store: workspace, git: git, remote: client))
            agent.replaceProjectTools(plugins.reload())
            agent.pluginPrompt = plugins.promptSections.joined(separator: "\n")
            await mcp.connectAll(into: agent)
            agent.start()
                    loops.requestNotificationPermission()
                    loops.startTicking()
                    loops.scheduleBackgroundRefresh()
                }
                .onChange(of: workspace.activeSandbox) { _, _ in
                    // Wipe sandbox switched — git backend must follow the active root.
                    let git = MobileGitClient(root: workspace.root, token: { SecureStore().read("oauth.github.access") ?? "" })
                    agent.setGitClient(git)
                    agent.register(AgentTools.runtime(shell: shell, store: workspace, git: git, remote: client))
                }
                .onChange(of: workspace.selectedProjectID) { _, projectID in
                    // Every project owns its transcript, model context and tool root.
                    shell.resetForProject()
                    agent.cancel()
                    agent.selectProject(projectID)
                    agent.setWorkspaceSnapshotProvider { try workspace.agentFiles() }
                    agent.setLearnedRulesProvider { MobileLessons.rulesText(root: workspace.root) }
                    agent.setMemoryQuestions(
                        provider: { asked in MobileLessons.memoryQuestions(root: workspace.root, asked: asked, text: localization.text) },
                        answer: { id, choice in MobileLessons.answerMemoryQuestion(id, choice: choice, root: workspace.root) }
                    )
                    agent.setPersonalMemoryProvider { hasProject in
                        MobilePersonalMemory.text(
                            userRoot: MobilePersonalMemory.defaultRoot(),
                            workspace: hasProject ? workspace.root : nil
                        )
                    }
                    let git = MobileGitClient(root: workspace.root, token: { SecureStore().read("oauth.github.access") ?? "" })
                    agent.setGitClient(git)
                    agent.register(AgentTools.workspace(workspace))
                    agent.register(AgentTools.runtime(shell: shell, store: workspace, git: git, remote: client))
                    agent.replaceProjectTools(plugins.reload())
                    agent.pluginPrompt = plugins.promptSections.joined(separator: "\n")
                    Task { await mcp.connectAll(into: agent) }
                }
                .onOpenURL { url in
                    if !githubOAuth.handleCallback(url) && !chatGPTOAuth.handleCallback(url) { client.consumePairURL(url) }
                }
                .alert(
                    localization.format("mobile.pairing.confirm.title", client.pendingPair?.host ?? ""),
                    isPresented: Binding(
                        get: { client.pendingPair != nil },
                        set: { if !$0 { client.cancelPendingPair() } }),
                    presenting: client.pendingPair
                ) { _ in
                    Button(localization.text("common.connect")) { Task { await client.confirmPendingPair() } }
                    Button(localization.text("common.cancel"), role: .cancel) { client.cancelPendingPair() }
                } message: { request in
                    Text(localization.format("mobile.pairing.confirm.message", request.code))
                }
        }
        .backgroundTask(.appRefresh(LoopScheduler.taskIdentifier)) {
            await loops.runDue()
            await loops.scheduleBackgroundRefresh()
        }
    }
}

private struct MobileWindowBehavior: ViewModifier {
    func body(content: Content) -> some View {
        // iPhone scenes are full-screen by default. SwiftUI's
        // windowFullScreenBehavior is unavailable on iOS, and
        // UIRequiresFullScreen is deprecated, so no letterboxing flag is
        // needed here.
        content
    }
}

/// Release the check-update endpoint reports for iOS, when it is newer than this build.
struct StoreUpdate: Identifiable {
    let version: String
    let notes: String
    let mandatory: Bool
    let url: URL
    var id: String { version }

    static let endpoint = URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/harness/check-update")!

    static func check(bundle: Bundle = .main) async -> StoreUpdate? {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "build", value: build),
        ]
        guard let (data, response) = try? await URLSession.shared.data(from: components.url!),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["update_available"] as? Bool == true,
              let link = (json["download_url"] as? String).flatMap(URL.init(string:)),
              // Only ever send the user to the App Store, whatever the server says.
              link.scheme == "https", link.host?.lowercased() == "apps.apple.com"
        else { return nil }
        return StoreUpdate(
            version: json["latest_version"] as? String ?? "",
            notes: json["release_notes"] as? String ?? "",
            mandatory: json["mandatory"] as? Bool ?? false,
            url: link
        )
    }
}

/// iOS can't update itself; this only points the user at the App Store. A
/// mandatory release keeps the alert up until the app is updated.
struct AppStoreUpdatePrompt: ViewModifier {
    @ObservedObject var localization: MobileLocalization
    @Environment(\.openURL) private var openURL
    @State private var update: StoreUpdate?

    func body(content: Content) -> some View {
        content
            .task { update = await StoreUpdate.check() }
            .alert(
                localization.text("updates.title"),
                isPresented: Binding(
                    get: { update != nil },
                    set: { if !$0, update?.mandatory != true { update = nil } }
                ),
                presenting: update
            ) { update in
                Button(localization.text("updates.openStore")) { openURL(update.url) }
                if !update.mandatory {
                    Button(localization.text("updates.later"), role: .cancel) {}
                }
            } message: { update in
                Text([localization.format("updates.available", update.version), update.notes]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
    }
}

