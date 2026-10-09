// Copyright (c) 2026 DOTS
// Startup, shortcuts, workspace mounting, plugins and vision fallback.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit

@MainActor
extension AppModel {
    /// Loads the project-scoped bridge before the first frame so the UI draws
    /// once with real data while keeping expensive refresh work deferred.
    public func prepareForFirstFrame() {
        guard !hasPreparedFirstFrame else { return }
        hasPreparedFirstFrame = true
        startBridgeIfNeeded()
    }

    public func startBridgeIfNeeded() {
        guard !hasStartedBridge else { return }
        hasStartedBridge = true
        bridge.start(workspacePath: sandboxRecoveryRequired ? "" : workspacePath)
        bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: activeSandbox?.branch)
    }

    public func startDeferredBridgeIfNeeded() {
        startBridgeIfNeeded()
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if deferredVoiceKeyLoad {
            deferredVoiceKeyLoad = false
            loadVoiceAPIKeyInBackground()
        }
        // Voice and speech runtimes are loaded purely on-demand when the user activates voice input
        // Speech servers an earlier run left behind (killed or crashed app). Off the main
        // thread: it runs `ps`.
        let speechRuntime = paths.runtime.appendingPathComponent("nemo-speech", isDirectory: true)
        Task.detached(priority: .utility) { NemotronRuntime.reapOrphans(runtimeRoot: speechRuntime) }
        // Show the gate immediately on a fresh install; loadLegal() refines it.
        let needsAcceptance = !legal.hasAnyAcceptance
        if legalNeedsAcceptance != needsAcceptance { legalNeedsAcceptance = needsAcceptance }
        Task { @MainActor [weak self] in await self?.loadLegal() }

        // Normally already done before the first frame (see prepareForFirstFrame).
        prepareForFirstFrame()

        // Let SwiftUI commit the first frame before plugin mounting, remote work
        // location (may touch SSH), the remote-control listener and the scheduler.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.hasBootstrapped else { return }

            self.startDeferredBridgeIfNeeded()
            self.restoreWorkLocation()
            self.remoteControl.start()
            self.remount(refreshCatalog: true)
            self.hasBootstrapped = true
            self.router.startUsagePolling()
            self.objectWillChange.send()

            // Older installs have a saved live-only model but no catalog cache.
            // Restore it in the background without requiring the picker to open.
            if self.router.pendingModelID != nil {
                Task { @MainActor [weak self] in
                    await self?.router.refreshModelsIfNeeded()
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                async let bridgeRefreshed: () = self.bridge.refreshConnection()
                async let marketRestored: () = self.marketplaceSession.restore()
                _ = await (bridgeRefreshed, marketRestored)
                self.syncAccountFromMarketplace()
                // The release poll is independent of plan recovery, so it runs
                // alongside it instead of adding its latency to startup.
                async let updates: () = self.updateChecker.checkForUpdates(manual: false)
                self.bridge.resolvePendingPlanIntents()
                await self.bridge.resumeRecoveredPlanIfNeeded()
                _ = await updates
            }

            self.scheduler.runsDueTasks = !self.isBackgroundDaemonEnabled
            self.scheduler.start()
        }
    }

    public func requestNotificationAuthorization() {
        desktopNotifications.requestAuthorization()
    }

    /// Headless bootstrap for the background scheduler daemon: mount plugins so
    /// the system prompt is assembled, then start the engine. No window, no
    /// workspace binding — each task carries its own workspace.
    public func startHeadless() {
        guard !hasStarted else { return }
        hasStarted = true
        catalog.refresh()
        remount(refreshCatalog: false)
        remoteControl.start()
        hasBootstrapped = true
        scheduler.runsDueTasks = true
        scheduler.start()
    }

    public func presentTasks() {
        commitNavigationDestination()
        isSimulatorPresented = false
        isTasksPresented = true
    }

    public func toggleSidebarVisibility() {
        navigationState.toggle()
    }

    public func shortcut(for action: KeyboardShortcutAction) -> UserKeyboardShortcut {
        keyboardShortcuts[action] ?? action.defaultShortcut
    }

    @discardableResult
    public func updateShortcut(
        _ shortcut: UserKeyboardShortcut,
        for action: KeyboardShortcutAction
    ) -> KeyboardShortcutUpdateResult {
        if let conflict = KeyboardShortcutAction.allCases.first(where: {
            $0 != action && self.shortcut(for: $0) == shortcut
        }) {
            return .conflict(conflict)
        }

        keyboardShortcuts[action] = shortcut
        host.settings.set(action.settingsKey, .string(shortcut.storedValue))
        persistSettings()
        return .saved
    }

    public func resetKeyboardShortcuts() {
        keyboardShortcuts = Dictionary(
            uniqueKeysWithValues: KeyboardShortcutAction.allCases.map { ($0, $0.defaultShortcut) }
        )
        for action in KeyboardShortcutAction.allCases {
            host.settings.remove(action.settingsKey)
        }
        persistSettings()
    }

    public var isBackgroundDaemonEnabled: Bool {
        host.settings.get("tasks.backgroundDaemon")?.bool ?? false
    }

    /// Enable/disable the launchd LaunchAgent that runs tasks while the app is
    /// closed. While the daemon owns execution the in-app engine stops firing
    /// due tasks so nothing runs twice.
    public func setBackgroundDaemonEnabled(_ enabled: Bool) throws {
        if enabled {
            try SchedulerService.install()
        } else {
            SchedulerService.uninstall()
        }
        host.settings.set("tasks.backgroundDaemon", .bool(enabled))
        persistSettings()
        scheduler.runsDueTasks = !enabled
    }

    /// Runner for the in-app `TaskScheduler`. Task runs keep their output in the
    /// task-run store and never become project conversations.
    public func runScheduledTask(_ task: ScheduledTask) async -> TaskScheduler.RunResult {
        let runner = ScheduledTaskRunner(
            paths: paths,
            router: router,
            endpoint: endpoint,
            permissionMode: permissionMode,
            systemPrompt: { [weak self] in self?.bridge.effectiveSystemPromptReport() ?? "" }
        )
        return await runner.run(task)
    }

    func notifyScheduledTask(_ task: ScheduledTask, result: TaskScheduler.RunResult) {
        desktopNotifications.showScheduledTask(task, result: result)
    }

    public func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppCopy.text("workspace.use")
        panel.message = AppCopy.text("workspace.chooseMessage")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.setWorkspace(url.path)
            }
        }
    }

    public func revealWorkspace() {
        guard !workspacePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspacePath)])
    }

    public func remount() {
        remount(refreshCatalog: true)
    }

    // MARK: Plugin management


    /// Installs a `.dotsplugin` package the user picked. Unsigned, untrusted.
    public func installPluginFile(_ url: URL) throws {
        try pluginInstaller.install(package: url, signature: nil, trust: .untrusted)
        remount()
    }

    public func removePlugin(id: String) throws {
        try pluginInstaller.remove(id: id)
        remount()
    }

    /// Packs an already-installed plugin folder into a shareable `.dotsplugin`.
    public func exportPlugin(id: String, to url: URL) throws {
        let folder = paths.plugins.appendingPathComponent(id, isDirectory: true)
        try PluginPackage.pack(folder: folder, to: url)
    }

    /// Read-only app state a plugin can pull via `harness.host("<topic>")`.
    /// Closures run on every plugin read — keep them to already-computed values.
    func registerHostDataTopics() {
        let hostData = host.hostData
        hostData.register("app") { [weak self] in
            let info = Bundle.main.infoDictionary
            return .object([
                "version": .string(info?["CFBundleShortVersionString"] as? String ?? ""),
                "build": .string(info?["CFBundleVersion"] as? String ?? ""),
                "platform": .string("macos"),
                "locale": .string(self?.appLanguage.localeIdentifier ?? "en"),
            ])
        }
        hostData.register("workspace") { [weak self] in
            let path = self?.workspacePath ?? ""
            return .object([
                "path": .string(path),
                "hasWorkspace": .bool(!path.isEmpty),
            ])
        }
        hostData.register("model") { [weak self] in
            .object(["selectedId": .string(self?.selectedModelID ?? "")])
        }
    }

    public var visionPluginInstalled: Bool {
        catalog.entries.contains { $0.manifest.id == VisionFallbackDefaults.pluginID }
    }

    public var visionPluginEnabled: Bool {
        catalog.entries.first(where: { $0.manifest.id == VisionFallbackDefaults.pluginID })?.enabled == true
    }

    public var visionState: VisionFallbackState {
        host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self)?.state ?? .unavailable
    }

    public var visionModelBytes: Int64 {
        host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self)?.modelBytes
            ?? VisionFallbackDefaults.modelBytes
    }

    public func setVisionPluginEnabled(_ enabled: Bool) {
        catalog.setEnabled(VisionFallbackDefaults.pluginID, enabled)
        remount()
    }

    public func installVisionPlugin() async throws {
        guard let installer = host.getService(
            VisionFallbackDefaults.installerServiceName,
            as: VisionFallbackInstaller.self
        ) else { throw PluginError.package("Vision marketplace installer is unavailable.") }
        _ = try await installer.install()
        objectWillChange.send()
    }

    public func prepareVision() async throws {
        guard let service = host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self) else {
            throw PluginError.package("Vision plugin is not installed.")
        }
        visionModelProgress = 0
        do {
            try await service.prepare(progress: { [weak self] value in
                Task { @MainActor in self?.visionModelProgress = min(1, max(0, value)) }
            })
            visionModelProgress = 1
        } catch {
            visionModelProgress = 0
            throw error
        }
        objectWillChange.send()
    }

    public func deleteVisionModel() throws {
        guard let service = host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self) else {
            throw PluginError.package("Vision plugin is not installed.")
        }
        try service.deleteModel()
        visionModelProgress = 0
        objectWillChange.send()
    }

    public func removeVisionPlugin() throws {
        host.unmountAll()
        let pluginDirectory = paths.plugins.appendingPathComponent(VisionFallbackDefaults.pluginID, isDirectory: true)
        let modelDirectory = paths.models
            .appendingPathComponent("vision", isDirectory: true)
            .appendingPathComponent("smolvlm-256m-q8", isDirectory: true)
        if FileManager.default.fileExists(atPath: pluginDirectory.path) {
            try FileManager.default.removeItem(at: pluginDirectory)
        }
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
        remount()
    }

    func remount(refreshCatalog: Bool) {
        if refreshCatalog {
            catalog.refresh()
        }
        skills.refresh()
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)
        _ = host.mount(document)
        bridge.updateSystemPrompt(host.prompt.assembledText())
        visionModelProgress = visionState == .ready ? 1 : 0
        objectWillChange.send()
    }
}
