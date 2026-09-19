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
    private var runtimeArchive: URL {
        paths.runtime.appendingPathComponent("nemo-speech.tar.gz")
    }
    private var runtimeRoot: URL {
        paths.runtime.appendingPathComponent("nemo-speech", isDirectory: true)
    }

    public init(paths: SupportPaths, port: Int = NemotronRuntime.defaultPort) {
        self.paths = paths
        self.port = port
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

    public func start() throws -> URL {
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
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "serve",
            "--asr-model", modelURL.path,
            "--device", device,
            "--no-ui",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--endpointing",
            "--stop-history-eou-ms", "800",
        ]
        process.currentDirectoryURL = runtimeRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        return serverURL
    }

    public func stop() {
        process?.terminate()
        process = nil
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
