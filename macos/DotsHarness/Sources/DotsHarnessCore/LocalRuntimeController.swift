// Copyright (c) 2026 DOTS
// Native local model install / serve, then register as a local endpoint.

import Foundation
import PluginRuntime

@MainActor
public final class LocalRuntimeController: ObservableObject {
    @Published public var runtimeReady = false
    @Published public var mlxReady = false
    @Published public var runtimeVersion: String?
    @Published public var runningModelID: String?
    @Published public var serving = false
    @Published public var downloads: [String: Double] = [:]
    @Published public var status: String = AppCopy.text("common.idle")
    @Published public var error: String?
    @Published public var installed: Set<String> = []
    @Published public var devices: [LocalDevice] = []
    /// Context window of the model being served, as the server reports it.
    @Published public var servedContext: Int?
    @Published public var settings: LocalRuntimeSettings {
        didSet { if settings != oldValue { runtime.saveSettings(settings) } }
    }

    public let runtime: LocalRuntime
    public let router: RouterController

    public init(paths: SupportPaths, router: RouterController) {
        self.runtime = LocalRuntime(paths: paths)
        self.router = router
        self.settings = runtime.loadSettings()
        self.runtimeVersion = LocalRuntime.llamaTag
        refreshInstalled()
    }

    public var mlxSupported: Bool { LocalRuntime.mlxSupported }

    /// Catalog GGUFs plus the files the user imported.
    public var models: [LocalModelSpec] {
        LocalModelCatalog.models + settings.importedModels.map(LocalModelSpec.imported(path:))
    }

    /// Everything that may be on disk: the catalog, imports and Hugging Face downloads.
    public var allModels: [LocalModelSpec] { models + LocalModelCatalog.mlxModels + settings.hubModels }

    public var memoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// "Apple M3 Pro · 13.3 GB" once the runtime can list devices, else RAM only.
    public var hardwareSummary: String {
        let memory = LocalModelCatalog.prettyBytes(Int64(memoryBytes))
        guard let gpu = devices.max(by: { $0.memoryMiB < $1.memoryMiB }) else {
            return AppCopy.format("local.hardwareMemory", memory)
        }
        let vram = LocalModelCatalog.prettyBytes(Int64(gpu.memoryMiB) * 1_048_576)
        return AppCopy.format("local.hardwareGPU", gpu.name, vram, memory)
    }

    /// Whether the model fits the GPU (or, without one, system memory).
    public func fits(_ spec: LocalModelSpec) -> Bool {
        let available = devices.map { UInt64($0.memoryMiB) * 1_048_576 }.max() ?? memoryBytes
        return UInt64(spec.minMemoryGB) * 1_073_741_824 <= available
    }

    public func refreshInstalled() {
        installed = Set(allModels.filter { runtime.isInstalled($0) }.map(\.id))
        serving = runtime.isServing()
        runningModelID = runtime.runningModelID()
        runtimeReady = runtime.runtimeInstalled()
        mlxReady = runtime.runtimeInstalled(.mlx)
        if !serving { servedContext = nil }
    }

    public func refreshDevices() async {
        devices = await runtime.devices()
    }

    public func installRuntime(_ engine: LocalEngine = .llama) async {
        error = nil
        let key = engine == .mlx ? "mlx" : "runtime"
        status = AppCopy.text(engine == .mlx ? "local.installMLX" : "local.downloadingRuntime")
        downloads[key] = 0
        do {
            let report: @Sendable (FileDownloader.Progress) -> Void = { [weak self] progress in
                Task { @MainActor in self?.downloads[key] = progress.fraction * 0.99 }
            }
            if engine == .mlx {
                try await runtime.ensureMLX(progress: report)
            } else {
                try await runtime.ensureRuntime(progress: report)
                await refreshDevices()
            }
            refreshInstalled()
            downloads[key] = 1
            status = AppCopy.text("local.runtimeReady")
        } catch {
            downloads[key] = nil
            self.error = error.localizedDescription
            status = AppCopy.text("local.runtimeInstallFailed")
        }
    }

    public func download(_ spec: LocalModelSpec) async {
        error = nil
        downloads[spec.id] = 0
        status = AppCopy.format("local.downloadingModel", spec.name)
        do {
            if !runtime.runtimeInstalled(spec.engine) {
                await installRuntime(spec.engine)
                if let error { throw RouterError(error) }
            }
            try await runtime.downloadModel(spec) { [weak self] progress in
                Task { @MainActor in
                    self?.downloads[spec.id] = progress.fraction
                    self?.status = AppCopy.format("local.modelProgress", spec.name, Int(progress.fraction * 100))
                }
            }
            downloads[spec.id] = 1
            if spec.id.hasPrefix("hf:"), !settings.hubModels.contains(where: { $0.id == spec.id }) {
                settings.hubModels.append(spec)
            }
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
            if !runtime.runtimeInstalled(spec.engine) {
                await installRuntime(spec.engine)
                if let error { throw RouterError(error) }
            }
            guard runtime.isInstalled(spec) else {
                throw RouterError(AppCopy.format("localRuntime.downloadFirst", spec.name))
            }
            status = AppCopy.format("local.startingModel", spec.name)
            _ = try runtime.start(model: spec, settings: settings)
            let ready = await runtime.waitUntilReady()
            refreshInstalled()
            if !ready {
                throw RouterError(AppCopy.format("local.serverNotReady", LocalRuntime.defaultPort) + "\n" + runtime.logTail())
            }
            // The router must budget against what the server allocated, not what
            // was asked for: llama.cpp shrinks the context to fit memory.
            let requested = runtime.requestedContext(for: spec, settings: settings)
            let context = spec.engine == .mlx ? requested : (await runtime.servedContext() ?? requested)
            servedContext = context
            await router.publishLocalNode(
                name: spec.name,
                prefix: LocalRuntime.nodePrefix,
                baseURL: runtime.serverURL.absoluteString,
                model: spec.engine == .mlx ? LocalRuntime.mlxModelID : spec.id,
                contextWindow: context
            )
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
        if let path = spec.localPath {
            // An imported file belongs to the user: forget it, never delete it.
            settings.importedModels.removeAll { $0 == path }
        } else {
            try? FileManager.default.removeItem(at: runtime.modelURL(spec))
            try? FileManager.default.removeItem(at: runtime.modelURL(spec).appendingPathExtension("part"))
            settings.hubModels.removeAll { $0.id == spec.id }
        }
        downloads[spec.id] = nil
        refreshInstalled()
        status = AppCopy.format("local.modelRemoved", spec.name)
    }

    public func importModel(at url: URL) {
        guard url.pathExtension.lowercased() == "gguf", !settings.importedModels.contains(url.path) else { return }
        settings.importedModels.append(url.path)
        refreshInstalled()
    }
}
