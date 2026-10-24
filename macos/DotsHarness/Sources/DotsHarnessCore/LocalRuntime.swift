// Copyright (c) 2026 DOTS
// Installs a pinned llama.cpp (Metal) or native MLX server and serves one local
// model over OpenAI-compatible HTTP.

import Foundation
import HarnessPluginKit
import PluginRuntime

public struct LocalRuntimeState: Sendable, Equatable {
    public var runtimeReady: Bool
    public var runtimeVersion: String?
    public var serverURL: URL?
    public var runningModelID: String?
    public var downloads: [String: Double]
    public var status: String
    public var error: String?

    public static let idle = LocalRuntimeState(
        runtimeReady: false,
        runtimeVersion: nil,
        serverURL: nil,
        runningModelID: nil,
        downloads: [:],
        status: AppCopy.text("common.idle"),
        error: nil
    )
}

/// User tuning for the bundled servers. Zero / empty / "auto" leave the choice
/// to the runtime, which already fits layers and context to the device memory.
public struct LocalRuntimeSettings: Codable, Sendable, Equatable {
    public var contextSize = 0
    public var gpuLayers = "auto"
    public var threads = 0
    public var batchSize = 0
    public var flashAttention = "auto"
    public var kvCacheType = ""
    public var extraArgs = ""
    public var mlxExtraArgs = ""
    public var importedModels: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contextSize = try values.decodeIfPresent(Int.self, forKey: .contextSize) ?? 0
        gpuLayers = try values.decodeIfPresent(String.self, forKey: .gpuLayers) ?? "auto"
        threads = try values.decodeIfPresent(Int.self, forKey: .threads) ?? 0
        batchSize = try values.decodeIfPresent(Int.self, forKey: .batchSize) ?? 0
        flashAttention = try values.decodeIfPresent(String.self, forKey: .flashAttention) ?? "auto"
        kvCacheType = try values.decodeIfPresent(String.self, forKey: .kvCacheType) ?? ""
        extraArgs = try values.decodeIfPresent(String.self, forKey: .extraArgs) ?? ""
        mlxExtraArgs = try values.decodeIfPresent(String.self, forKey: .mlxExtraArgs) ?? ""
        importedModels = try values.decodeIfPresent([String].self, forKey: .importedModels) ?? []
    }
}

/// A compute device as `llama-server --list-devices` reports it.
public struct LocalDevice: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var memoryMiB: Int

    public init(id: String, name: String, memoryMiB: Int) {
        self.id = id
        self.name = name
        self.memoryMiB = memoryMiB
    }
}

public final class LocalRuntime: @unchecked Sendable {
    public static let defaultPort = 18765
    public static let nodePrefix = "local"

    /// The build behind llama.cpp's stable v0.5.0 (`nightly-tag.txt`). Pinned
    /// with checksums because the binary is executed: `releases/latest` no
    /// longer carries binaries, and a moving tag would run unreviewed code.
    public static let llamaTag = "b11146"
    public static let idleUnloadSeconds = 15
    /// The mlx-swift-lm release `dotsmlx` is built against (Package.swift).
    public static let mlxVersion = "3.32.3"
    /// Names the downloaded `dotsmlx` archive; bump with every republished build.
    public static let mlxServerBuild = "3.32.3-1"
    /// Model id `dotsmlx` answers to for the model it was started with.
    public static let mlxModelID = "default_model"

    public struct PinnedAsset: Sendable, Equatable {
        public var url: URL
        public var size: Int64
        public var sha256: String
    }

    public let paths: SupportPaths
    public let port: Int

    private var process: Process?
    private var runningModel: String?

    public init(paths: SupportPaths, port: Int = LocalRuntime.defaultPort) {
        self.paths = paths
        self.port = port
        paths.ensure()
        // The private Python + mlx-lm install that served MLX before `dotsmlx`.
        try? FileManager.default.removeItem(at: paths.runtime.appendingPathComponent("mlx", isDirectory: true))
    }

    public var serverURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }
    /// The release unpacks into its own folder; the server needs its sibling dylibs.
    public var llamaDirectory: URL { paths.runtime.appendingPathComponent("llama-\(Self.llamaTag)", isDirectory: true) }
    public var binaryURL: URL { llamaDirectory.appendingPathComponent("llama-server") }
    public var archiveURL: URL { paths.runtime.appendingPathComponent("llama.cpp.tar.gz") }
    public var logURL: URL { paths.runtime.appendingPathComponent("local-server.log") }
    public var settingsURL: URL { paths.runtime.appendingPathComponent("local-runtime.json") }
    /// `dotsmlx` and its `mlx.metallib`. A development build carries them beside
    /// the app executable (run.sh); a release downloads them on first use.
    public var mlxDirectory: URL { paths.runtime.appendingPathComponent("dotsmlx-\(Self.mlxServerBuild)", isDirectory: true) }
    public lazy var mlxServerURL: URL = {
        let bundled = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("dotsmlx")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : mlxDirectory.appendingPathComponent("dotsmlx")
    }()

    public static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    /// MLX only exists for Apple Silicon.
    public static var mlxSupported: Bool { hostArch == "arm64" }

    public static func llamaAsset(arch: String) -> PinnedAsset {
        let pinned: (size: Int64, sha256: String) = arch == "arm64"
            ? (11_189_714, "1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711")
            : (11_237_237, "305f0e3a17d2c01eb205cd0a62128357f1ec3b55329cb084d94e5ec0115d7a3b")
        let name = "llama-\(llamaTag)-bin-macos-\(arch).tar.gz"
        return PinnedAsset(
            url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(llamaTag)/\(name)")!,
            size: pinned.size,
            sha256: pinned.sha256
        )
    }

    /// Built by scripts/package-mlx-server.sh and stored in the `dotsherness-assets` R2
    /// bucket; 27 MB unpacked, so it stays out of the app.
    public static let mlxAsset = PinnedAsset(
        url: URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/assets/downloads/dotsmlx-\(mlxServerBuild)-macos-arm64.tar.gz")!,
        size: 8_123_529,
        sha256: "fc6e2df2fca8d04626eec8adf0f3f079939809b0acca3feb6edf563535230802"
    )

    // MARK: Settings

    public func loadSettings() -> LocalRuntimeSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(LocalRuntimeSettings.self, from: data) else {
            return LocalRuntimeSettings()
        }
        return settings
    }

    public func saveSettings(_ settings: LocalRuntimeSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    // MARK: Models

    public func modelURL(_ spec: LocalModelSpec) -> URL {
        if let path = spec.localPath { return URL(fileURLWithPath: path) }
        if spec.engine == .mlx {
            return paths.models.appendingPathComponent("mlx", isDirectory: true)
                .appendingPathComponent(spec.filename, isDirectory: true)
        }
        return paths.models.appendingPathComponent(spec.filename)
    }

    private func mlxMarker(_ spec: LocalModelSpec) -> URL { modelURL(spec).appendingPathComponent(".complete") }

    public func isInstalled(_ spec: LocalModelSpec) -> Bool {
        let fm = FileManager.default
        if spec.engine == .mlx { return fm.fileExists(atPath: mlxMarker(spec).path) }
        guard fm.fileExists(atPath: modelURL(spec).path) else { return false }
        if spec.localPath != nil { return true }
        return installedBytes(spec) >= max(1, spec.bytes / 2)
    }

    public func installedBytes(_ spec: LocalModelSpec) -> Int64 {
        let fm = FileManager.default
        let url = modelURL(spec)
        guard spec.engine == .mlx else {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    public func downloadModel(_ spec: LocalModelSpec, progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        guard spec.localPath == nil else { return }
        if spec.engine == .mlx { return try await downloadMLXModel(spec, progress: progress) }
        try await Self.retrying {
            try await FileDownloader.download(from: spec.url, to: self.modelURL(spec), expected: spec.bytes, sha256: spec.sha256, progress: progress)
        }
    }

    /// An MLX model is a flat Hugging Face repository. Every LFS file is checked
    /// against the digest the listing publishes.
    private func downloadMLXModel(_ spec: LocalModelSpec, progress: (@Sendable (FileDownloader.Progress) -> Void)?) async throws {
        guard let repo = spec.repo, let listing = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main") else {
            throw RouterError(AppCopy.format("localRuntime.downloadFirst", spec.name))
        }
        let (data, response) = try await URLSession.shared.data(from: listing)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RouterError(AppCopy.format("download.failed", status))
        }
        let files: [(path: String, size: Int64, sha256: String?)] = rows.compactMap { row in
            guard row["type"] as? String == "file", let path = row["path"] as? String,
                  !path.hasPrefix("."), path != "README.md" else { return nil }
            return (path, (row["size"] as? NSNumber)?.int64Value ?? 0, (row["lfs"] as? [String: Any])?["oid"] as? String)
        }
        let total = files.reduce(0) { $0 + $1.size }
        let directory = modelURL(spec)
        var done: Int64 = 0
        for file in files {
            guard let remote = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.path)") else { continue }
            let finished = done
            try await Self.retrying {
                try await FileDownloader.download(
                    from: remote, to: directory.appendingPathComponent(file.path), expected: file.size, sha256: file.sha256
                ) { part in
                    progress?(FileDownloader.Progress(received: finished + part.received, expected: total, bytesPerSecond: part.bytesPerSecond))
                }
            }
            done += file.size
        }
        FileManager.default.createFile(atPath: mlxMarker(spec).path, contents: nil)
    }

    /// Large downloads resume from their `.part` file, so a dropped connection
    /// only needs another attempt.
    private static func retrying(attempts: Int = 4, _ operation: () async throws -> Void) async throws {
        for attempt in 1...attempts {
            do { return try await operation() } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == attempts { throw error }
                try await Task.sleep(for: .seconds(attempt * 2))
            }
        }
    }

    // MARK: Runtimes

    public func runtimeInstalled(_ engine: LocalEngine = .llama) -> Bool {
        FileManager.default.isExecutableFile(atPath: (engine == .mlx ? mlxServerURL : binaryURL).path)
    }

    public func runningModelID() -> String? { runningModel }

    public func isServing() -> Bool { process?.isRunning == true }

    public func ensureRuntime(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        if runtimeInstalled() { return }
        let asset = Self.llamaAsset(arch: Self.hostArch)
        try await Self.retrying {
            try await FileDownloader.download(from: asset.url, to: self.archiveURL, expected: asset.size, sha256: asset.sha256, progress: progress)
        }
        try? FileManager.default.removeItem(at: llamaDirectory)
        _ = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archiveURL.path, "-C", paths.runtime.path])
        try? FileManager.default.removeItem(at: archiveURL)
        guard runtimeInstalled() else {
            throw RouterError(AppCopy.text("localRuntime.serverMissingAfterUnpack"))
        }
    }

    public func ensureMLX(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        guard Self.mlxSupported else { throw RouterError(AppCopy.text("localRuntime.installFirst")) }
        if runtimeInstalled(.mlx) { return }
        let archive = paths.runtime.appendingPathComponent("dotsmlx.tar.gz")
        try await Self.retrying {
            try await FileDownloader.download(from: Self.mlxAsset.url, to: archive, expected: Self.mlxAsset.size, sha256: Self.mlxAsset.sha256, progress: progress)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: mlxDirectory)
        try fm.createDirectory(at: mlxDirectory, withIntermediateDirectories: true)
        _ = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", mlxDirectory.path])
        try? fm.removeItem(at: archive)
        guard runtimeInstalled(.mlx) else {
            throw RouterError(AppCopy.text("localRuntime.serverMissingAfterUnpack"))
        }
    }

    /// GPUs llama.cpp can offload to on this Mac. Empty until the runtime is installed.
    public func devices() async -> [LocalDevice] {
        guard runtimeInstalled(), let output = try? await run(binaryURL, ["--list-devices"]) else { return [] }
        return Self.parseDevices(output)
    }

    /// Lines look like `  MTL0: Apple M3 Pro (13639 MiB, 13639 MiB free)`.
    /// Entries without memory (the BLAS/CPU accelerators) are not GPUs.
    public static func parseDevices(_ output: String) -> [LocalDevice] {
        output.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^\s+(\w+): (.+) \((\d+) MiB, \d+ MiB free\)\s*$/),
                  let memory = Int(match.3), memory > 0 else { return nil }
            return LocalDevice(id: String(match.1), name: String(match.2), memoryMiB: memory)
        }
    }

    /// Context to request when the user left it automatic: the model's own
    /// limit, capped so the KV cache stays small next to the weights.
    public static func automaticContext(for spec: LocalModelSpec, memoryBytes: UInt64) -> Int {
        let cap = memoryBytes >= 24 * 1_073_741_824 ? 32_768 : 16_384
        return min(spec.context, cap)
    }

    public func requestedContext(for spec: LocalModelSpec, settings: LocalRuntimeSettings) -> Int {
        settings.contextSize > 0
            ? settings.contextSize
            : Self.automaticContext(for: spec, memoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    public static func llamaArguments(
        modelPath: String, alias: String, port: Int, context: Int, settings: LocalRuntimeSettings
    ) -> [String] {
        var arguments = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(context),
            "--alias", alias,
            "--jinja",
            // One agent talks to this server; more slots would split the context.
            "--parallel", "1",
            // Weights and KV cache leave memory after this long without a request;
            // the next request reloads them. /health and /props do not count.
            "--sleep-idle-seconds", String(idleUnloadSeconds),
            "--gpu-layers", settings.gpuLayers.isEmpty ? "auto" : settings.gpuLayers,
        ]
        if settings.threads > 0 { arguments += ["--threads", String(settings.threads)] }
        if settings.batchSize > 0 { arguments += ["--batch-size", String(settings.batchSize)] }
        if ["on", "off"].contains(settings.flashAttention) { arguments += ["--flash-attn", settings.flashAttention] }
        if !settings.kvCacheType.isEmpty {
            arguments += ["--cache-type-k", settings.kvCacheType, "--cache-type-v", settings.kvCacheType]
        }
        // ponytail: whitespace split, no quoting. Paths with spaces need a real parser.
        return arguments + settings.extraArgs.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public func start(model spec: LocalModelSpec, settings: LocalRuntimeSettings = LocalRuntimeSettings()) throws -> URL {
        if process?.isRunning == true, runningModel == spec.id {
            return serverURL
        }
        stop()
        guard runtimeInstalled(spec.engine) else { throw RouterError(AppCopy.text("localRuntime.installFirst")) }
        guard isInstalled(spec) else { throw RouterError(AppCopy.format("localRuntime.downloadFirst", spec.name)) }

        let process = Process()
        if spec.engine == .mlx {
            process.executableURL = mlxServerURL
            process.arguments = [
                "--model", modelURL(spec).path,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--max-tokens", "8192",
                "--idle-seconds", String(Self.idleUnloadSeconds),
            ] + settings.mlxExtraArgs.split(whereSeparator: \.isWhitespace).map(String.init)
        } else {
            process.executableURL = binaryURL
            process.arguments = Self.llamaArguments(
                modelPath: modelURL(spec).path, alias: spec.id, port: port,
                context: requestedContext(for: spec, settings: settings), settings: settings
            )
            process.currentDirectoryURL = llamaDirectory
        }
        // A file, not a pipe: nobody drains a pipe, and a full one blocks the server.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        try process.run()
        self.process = process
        self.runningModel = spec.id
        return serverURL
    }

    public func stop() {
        process?.terminate()
        process = nil
        runningModel = nil
    }

    /// Loading weights takes far longer than binding the port, so this waits
    /// for `/health` to report ready rather than for any HTTP answer.
    public func waitUntilReady(timeoutMs: Int = 180_000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if process?.isRunning == false { return false }
            if await ping() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await ping()
    }

    public func ping() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// The context the running server really allocated (llama.cpp may shrink
    /// the request to fit memory). Nil for MLX, which has no fixed window.
    public func servedContext() async -> Int? {
        await LocalServerProbe.contextWindows(baseURL: serverURL.absoluteString)[LocalServerProbe.anyModel]
    }

    /// Last lines of the server log, for an error the user can act on.
    public func logTail(lines: Int = 6) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// Runs a helper to completion off the caller's thread and returns its output.
    private func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        let output = paths.runtime.appendingPathComponent("helper-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        try? handle.close()
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        guard status == 0 else {
            let tail = text.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw RouterError(AppCopy.format("localRuntime.helperFailed", executable.lastPathComponent, Int(status)) + "\n" + tail)
        }
        return text
    }
}
