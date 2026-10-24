// Copyright (c) 2026 DOTS
// Optional on-demand NeMo-Speech.cpp runtime for local Nemotron voice input.

import Foundation
import PluginRuntime

public final class NemotronRuntime: @unchecked Sendable {
    public static let defaultPort = 18_766
    public static let model = LocalVoiceModel.nemotron

    public let paths: SupportPaths
    public let port: Int

    private var process: Process?
    private var idleTask: Task<Void, Never>?
    private let activityLock = NSLock()
    private var lastActivity = Date.distantPast
    /// The server keeps the ASR model on the GPU (about 1 GB resident). It stops after this
    /// long without audio or a start, and the next dictation press starts it again.
    public static let defaultIdleStopAfter: TimeInterval = 60
    public let idleStopAfter: TimeInterval

    private var runtimeArchive: URL {
        paths.runtime.appendingPathComponent("nemo-speech.tar.gz")
    }
    private var runtimeRoot: URL {
        paths.runtime.appendingPathComponent("nemo-speech", isDirectory: true)
    }

    public init(
        paths: SupportPaths,
        port: Int = NemotronRuntime.defaultPort,
        idleStopAfter: TimeInterval = NemotronRuntime.defaultIdleStopAfter
    ) {
        self.paths = paths
        self.port = port
        self.idleStopAfter = idleStopAfter
        paths.ensure()
    }

    deinit {
        stop()
    }

    public var serverURL: URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    public var modelURL: URL {
        paths.models.appendingPathComponent(Self.model.filename)
    }

    private let binaryCacheLock = NSLock()
    private var cachedBinaryURL: URL?

    /// The runtime archive nests its files, so the binary is usually not at the expected
    /// path and finding it walks the whole runtime folder. `isReady` is read whenever
    /// the composer redraws, so the location is remembered (and re-checked with one stat).
    public var binaryURL: URL {
        binaryCacheLock.lock()
        let cached = cachedBinaryURL
        binaryCacheLock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }

        let expected = runtimeRoot.appendingPathComponent("bin/nemo-speech")
        let found: URL
        if FileManager.default.fileExists(atPath: expected.path) {
            found = expected
        } else if let scanned = firstFile(named: "nemo-speech", under: runtimeRoot) {
            found = scanned
        } else {
            return expected   // not installed: nothing worth remembering
        }
        binaryCacheLock.lock()
        cachedBinaryURL = found
        binaryCacheLock.unlock()
        return found
    }

    public var isModelInstalled: Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == Self.model.bytes
    }

    public func runtimeInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    public var isReady: Bool {
        runtimeInstalled() && isModelInstalled
    }

    public func ensureRuntime(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        if runtimeInstalled() { return }

        let asset = try Self.macAsset()
        try await FileDownloader.download(
            from: asset.url,
            to: runtimeArchive,
            expected: asset.bytes,
            sha256: asset.sha256,
            progress: progress
        )

        let fm = FileManager.default
        let staging = paths.runtime.appendingPathComponent("nemo-speech-staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let extractor = Process()
        extractor.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extractor.arguments = ["-xzf", runtimeArchive.path, "-C", staging.path]
        extractor.standardOutput = Pipe()
        extractor.standardError = Pipe()
        try extractor.run()
        extractor.waitUntilExit()

        guard extractor.terminationStatus == 0,
              let stagedBinary = firstFile(named: "nemo-speech", under: staging) else {
            try? fm.removeItem(at: staging)
            throw RouterError(AppCopy.text("voice.runtime.unpackFailed"))
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedBinary.path)
        guard fm.isExecutableFile(atPath: stagedBinary.path) else {
            try? fm.removeItem(at: staging)
            throw RouterError(AppCopy.text("voice.runtime.binaryMissing"))
        }

        try? fm.removeItem(at: runtimeRoot)
        try fm.moveItem(at: staging, to: runtimeRoot)
        guard runtimeInstalled() else {
            throw RouterError(AppCopy.text("voice.runtime.binaryMissing"))
        }
    }

    public func ensureModel(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        guard let url = Self.model.url else {
            throw RouterError(AppCopy.text("voice.modelURLMissing"))
        }
        try await FileDownloader.download(
            from: url,
            to: modelURL,
            expected: Self.model.bytes,
            progress: progress
        )
    }

    /// Marks dictation in use. Captured audio calls this too, so an open mic keeps the server up.
    public func noteActivity() {
        activityLock.withLock { lastActivity = Date() }
    }

    private var lastActivityDate: Date {
        activityLock.withLock { lastActivity }
    }

    public func start() throws -> URL {
        noteActivity()
        if process?.isRunning == true {
            return serverURL
        }
        stop()
        guard runtimeInstalled() else {
            throw RouterError(AppCopy.text("voice.runtime.missing"))
        }
        guard isModelInstalled else {
            throw RouterError(AppCopy.text("voice.modelNotReady"))
        }

        #if arch(arm64)
        let device = "metal"
        #else
        let device = "cpu"
        #endif
        // A server left over from an earlier run that died without stopping it.
        Self.reapOrphans(runtimeRoot: runtimeRoot)

        let process = Process()
        (process.executableURL, process.arguments) = Self.guardedLaunch(
            executable: binaryURL,
            arguments: [
                "serve",
                "--asr-model", modelURL.path,
                "--device", device,
                "--no-ui",
                "--host", "127.0.0.1",
                "--port", String(port),
                "--endpointing",
                "--stop-history-eou-ms", "800",
                // Warmup took 11 s to ready; without it the server is ready in ~1 s and
                // the first request costs ~0.4 s more. Measured on the 0.6B q8_0 model.
                "--no-warmup",
                // Dictation is one stream at a time. Each arena slot reserves device rows for a
                // streaming state (~11 MB each); the default 16 cost ~160 MB resident for nothing.
                "--asr.batching.state_arena_slots", "2",
            ],
            parentPID: getpid()
        )
        process.currentDirectoryURL = runtimeRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        armIdleStop()
        return serverURL
    }

    public func stop() {
        idleTask?.cancel()
        idleTask = nil
        process?.terminate()
        process = nil
        // The supervisor takes the server down with it, unless it died first; then the server
        // is orphaned, out of reach of `process`, and would keep the model resident.
        let root = runtimeRoot
        Task.detached(priority: .utility) { Self.reapOrphans(runtimeRoot: root) }
    }

    private func armIdleStop() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.idleStopAfter else { return }
                try? await Task.sleep(for: .seconds(min(15, max(1, interval / 4))))
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(self.lastActivityDate) >= self.idleStopAfter {
                    self.stop()
                    return
                }
            }
        }
    }

    /// True while the speech server process is alive (it may still be loading the model).
    public var isRunning: Bool { process?.isRunning == true }

    // MARK: - Orphan protection

    /// A child does not die with its parent on macOS. When the app is force-quit, killed
    /// or crashes, the speech server (a model held on the GPU) would run on for good, one
    /// more per launch. The server is therefore started through a small supervisor that
    /// watches the app's pid and stops the server as soon as the app is gone. Stopping
    /// the supervisor (TERM) stops the server too.
    static func guardedLaunch(executable: URL, arguments: [String], parentPID: Int32) -> (URL, [String]) {
        let script = """
        parent=$1; shift
        "$@" &
        child=$!
        trap 'kill $child 2>/dev/null; exit 0' TERM INT HUP
        while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do
            sleep 1 &
            wait $!
        done
        kill $child 2>/dev/null
        wait $child 2>/dev/null
        """
        return (
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", script, "dots-speech-guard", String(parentPID), executable.path] + arguments
        )
    }

    /// Stops speech servers of this runtime whose app is gone (parent is launchd). Servers
    /// started before the supervisor existed, or by a build without it, are handled here.
    /// A server that still has a live parent (another running instance) is left alone.
    @discardableResult
    static func reapOrphans(runtimeRoot: URL) -> Int {
        let list = Process()
        let output = Pipe()
        list.executableURL = URL(fileURLWithPath: "/bin/ps")
        list.arguments = ["-axo", "pid=,ppid=,command="]
        list.standardOutput = output
        list.standardError = FileHandle.nullDevice
        guard (try? list.run()) != nil else { return 0 }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        list.waitUntilExit()

        let marker = runtimeRoot.path + "/"
        var reaped = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  fields[1] == "1",
                  fields[2].hasPrefix(marker),
                  fields[2].contains(" serve ") else { continue }
            if kill(pid, SIGTERM) == 0 { reaped += 1 }
        }
        return reaped
    }

    public func waitUntilReady(timeoutMs: Int = 60_000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if process?.isRunning == false { return false }
            if await ping() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await ping()
    }

    public func ping() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/ready") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 1.5))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status)
        } catch {
            return false
        }
    }

    public func deleteModel() throws {
        stop()
        let fm = FileManager.default
        if fm.fileExists(atPath: modelURL.path) {
            try fm.removeItem(at: modelURL)
        }
        let partial = modelURL.appendingPathExtension("part")
        if fm.fileExists(atPath: partial.path) {
            try fm.removeItem(at: partial)
        }
    }

    /// Removes only runtime artifacts created by a failed first install.
    /// The Settings delete action intentionally calls `deleteModel()` instead.
    public func removeRuntimeArtifacts(includePartial: Bool = false) throws {
        stop()
        let fm = FileManager.default
        if fm.fileExists(atPath: runtimeRoot.path) {
            try fm.removeItem(at: runtimeRoot)
        }
        if fm.fileExists(atPath: runtimeArchive.path) {
            try fm.removeItem(at: runtimeArchive)
        }
        if includePartial {
            let partial = runtimeArchive.appendingPathExtension("part")
            if fm.fileExists(atPath: partial.path) {
                try fm.removeItem(at: partial)
            }
        }
    }

    public struct RuntimeAsset: Equatable, Sendable {
        public let url: URL
        public let bytes: Int64
        public let sha256: String

        public init(url: URL, bytes: Int64, sha256: String) {
            self.url = url
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public static func macAsset(arch: String = hostArch) throws -> RuntimeAsset {
        let name: String
        let bytes: Int64
        let sha256: String

        switch arch {
        case "arm64":
            name = "nemo-speech-0.1.0-macos-aarch64-metal.tar.gz"
            bytes = 3_465_028
            sha256 = "f1dff4f9dd9c96214f8cb78b982812459132df8a4ad1a42409fd94de4a366244"
        case "x64":
            name = "nemo-speech-0.1.0-macos-x86_64-cpu.tar.gz"
            bytes = 3_618_245
            sha256 = "042a4612e07460fab6a39b5d862aa1e39d0ac3eaedfdb979f3f5fc12de510c20"
        default:
            throw RouterError("Unsupported macOS architecture: \(arch)")
        }

        return RuntimeAsset(
            url: URL(string: "https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v0.1.0/\(name)")!,
            bytes: bytes,
            sha256: sha256
        )
    }

    public static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    private func firstFile(named name: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let file as URL in enumerator where file.lastPathComponent == name {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return file
            }
        }
        return nil
    }
}
