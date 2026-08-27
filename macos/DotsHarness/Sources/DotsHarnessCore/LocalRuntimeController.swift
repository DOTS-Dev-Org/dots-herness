// Copyright (c) 2026 DOTS
// Native local model install / serve, then register as a local endpoint.

import Foundation
import PluginRuntime

@MainActor
public final class LocalRuntimeController: ObservableObject {
    @Published public var runtimeReady = false
    @Published public var runtimeVersion: String?
    @Published public var runningModelID: String?
    @Published public var serving = false
    @Published public var downloads: [String: Double] = [:]
    @Published public var status: String = AppCopy.text("common.idle")
    @Published public var error: String?
    @Published public var installed: Set<String> = []

    public let runtime: LocalRuntime
    public let router: RouterController

    public init(paths: SupportPaths, router: RouterController) {
        self.runtime = LocalRuntime(paths: paths)
        self.router = router
        refreshInstalled()
        runtimeReady = runtime.runtimeInstalled()
    }

    public func refreshInstalled() {
        installed = Set(LocalModelCatalog.models.filter { runtime.isInstalled($0) }.map(\.id))
        serving = runtime.isServing()
        runningModelID = runtime.runningModelID()
        runtimeReady = runtime.runtimeInstalled()
    }

    public func installRuntime() async {
        error = nil
        status = AppCopy.text("local.downloadingRuntime")
        downloads["runtime"] = 0
        do {
            try await runtime.ensureRuntime { [weak self] progress in
                Task { @MainActor in
                    self?.downloads["runtime"] = progress.fraction
                    self?.status = AppCopy.format("local.downloadingRuntimeProgress", Int(progress.fraction * 100))
                }
            }
            runtimeReady = true
            downloads["runtime"] = 1
            status = AppCopy.text("local.runtimeReady")
        } catch {
            self.error = error.localizedDescription
            status = AppCopy.text("local.runtimeInstallFailed")
        }
    }

    public func download(_ spec: LocalModelSpec) async {
        error = nil
        downloads[spec.id] = 0
        status = AppCopy.format("local.downloadingModel", spec.name)
        do {
            if !runtime.runtimeInstalled() {
                await installRuntime()
            }
            try await runtime.downloadModel(spec) { [weak self] progress in
                Task { @MainActor in
                    self?.downloads[spec.id] = progress.fraction
                    self?.status = AppCopy.format("local.modelProgress", spec.name, Int(progress.fraction * 100))
                }
            }
            downloads[spec.id] = 1
            refreshInstalled()
            status = AppCopy.format("local.modelDownloaded", spec.name)
        } catch {
            self.error = error.localizedDescription
            status = AppCopy.text("local.downloadFailed")
        }
    }

    public func start(_ spec: LocalModelSpec) async {
        error = nil
        do {
            guard runtime.runtimeInstalled() else {
                throw RouterError(AppCopy.text("localRuntime.installFirst"))
            }
            guard runtime.isInstalled(spec) else {
                throw RouterError(AppCopy.format("localRuntime.downloadFirst", spec.name))
            }
            status = AppCopy.format("local.startingModel", spec.name)
            _ = try runtime.start(model: spec)
            let ready = await runtime.waitUntilReady()
            refreshInstalled()
            if !ready {
                throw RouterError(AppCopy.format("local.serverNotReady", LocalRuntime.defaultPort))
            }
            await publishNode(for: spec)
            status = AppCopy.format("local.servingModel", spec.name, runtime.serverURL.absoluteString)
        } catch {
            self.error = error.localizedDescription
            status = AppCopy.text("local.startFailed")
            runtime.stop()
            refreshInstalled()
        }
    }

    public func stop() {
        runtime.stop()
        refreshInstalled()
        status = AppCopy.text("local.serverStopped")
    }

    public func delete(_ spec: LocalModelSpec) {
        if runningModelID == spec.id { stop() }
        try? FileManager.default.removeItem(at: runtime.modelURL(spec))
        try? FileManager.default.removeItem(at: runtime.modelURL(spec).appendingPathExtension("part"))
        downloads[spec.id] = nil
        refreshInstalled()
        status = AppCopy.format("local.modelRemoved", spec.name)
    }

    private func publishNode(for spec: LocalModelSpec) async {
        router.customName = spec.name
        router.customPrefix = LocalRuntime.nodePrefix
        router.customBaseURL = runtime.serverURL.absoluteString
        router.customAPIKey = ""
        router.customKind = .openai
        router.customAPIType = .chat
        if let existing = router.nodes.first(where: { $0.prefix == LocalRuntime.nodePrefix || $0.baseURL.contains(":\(LocalRuntime.defaultPort)") }) {
            await router.connectExistingNode(existing)
        } else {
            await router.createCustomNode(registerKey: true)
        }
    }
}
