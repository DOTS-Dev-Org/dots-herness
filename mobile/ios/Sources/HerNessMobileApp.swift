import SwiftUI

@main
struct HerNessMobileApp: App {
    @StateObject private var localization = MobileLocalization()
    @StateObject private var client: RemoteControlClient
    @StateObject private var workspace: LocalWorkspaceStore
    @StateObject private var shell: LocalShell
    @StateObject private var plugins: MobilePlugins
    @StateObject private var mcp = MCPRegistry()
    @StateObject private var loops: LoopScheduler
    @StateObject private var githubOAuth = GitHubOAuth()
    @StateObject private var chatGPTOAuth = ChatGPTOAuth()
    @StateObject private var agent = MobileAgent(
        apiKey: { SecureStore().read("phone.provider") ?? "" },
        systemPrompt: { HerNessMobileApp.systemPrompt },
        oauthToken: { SecureStore().read("oauth.openai.access") ?? "" },
        sessionAccountID: { SecureStore().read("oauth.openai.account") ?? "" })

    init() {
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
            let agent = MobileAgent(apiKey: { SecureStore().read("phone.provider") ?? "" }, systemPrompt: { Self.systemPrompt }, oauthToken: { SecureStore().read("oauth.openai.access") ?? "" }, sessionAccountID: { SecureStore().read("oauth.openai.account") ?? "" })
            agent.setWorkspaceSnapshotProvider { try workspace.agentFiles() }
            let git = MobileGitClient(root: workspace.root, token: { SecureStore().read("oauth.github.access") ?? "" })
            agent.setGitClient(git)
            agent.register(AgentTools.workspace(workspace))
            agent.register(AgentTools.runtime(shell: shell, store: workspace, git: git, remote: client))
            agent.register(plugins.reload())
            return agent
        })
    }

    static let systemPrompt = HerNessPrompt.phone

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(client)
                .environmentObject(localization)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(MobileWindowBehavior())
        .task {
            await chatGPTOAuth.refreshIfNeeded()
            agent.start()
            agent.setWorkspaceSnapshotProvider { try workspace.agentFiles() }
            let git = MobileGitClient(root: workspace.root, token: { SecureStore().read("oauth.github.access") ?? "" })
            agent.setGitClient(git)
            agent.register(AgentTools.workspace(workspace))
            agent.register(AgentTools.runtime(shell: shell, store: workspace, git: git, remote: client))
                    agent.register(plugins.reload())
                    agent.pluginPrompt = plugins.promptSections.joined(separator: "\n")
                    await mcp.connectAll(into: agent)
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
                .onOpenURL { url in
                    if !githubOAuth.handleCallback(url) && !chatGPTOAuth.handleCallback(url) { client.consumePairURL(url) }
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
