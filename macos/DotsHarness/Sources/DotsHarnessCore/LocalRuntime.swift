// Copyright (c) 2026 DOTS
// Downloads llama.cpp and serves a GGUF over OpenAI-compatible HTTP.

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

public final class LocalRuntime: @unchecked Sendable {
    public static let defaultPort = 18765
    public static let nodePrefix = "local"

    public let paths: SupportPaths
    public let port: Int

    private var process: Process?
    private var runningModel: String?

    public init(paths: SupportPaths, port: Int = LocalRuntime.defaultPort) {
        self.paths = paths
        self.port = port
        paths.ensure()
    }

    public var serverURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }
    public var binaryURL: URL { paths.runtime.appendingPathComponent("llama-server") }
    public var archiveURL: URL { paths.runtime.appendingPathComponent("llama.cpp.tar.gz") }

    public func modelURL(_ spec: LocalModelSpec) -> URL {
        paths.models.appendingPathComponent(spec.filename)
    }

    public func isInstalled(_ spec: LocalModelSpec) -> Bool {
        let url = modelURL(spec)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size >= max(1, spec.bytes / 2)
    }

    public func installedBytes(_ spec: LocalModelSpec) -> Int64 {
        let url = modelURL(spec)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func runtimeInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    public func runningModelID() -> String? { runningModel }

    public func isServing() -> Bool { process?.isRunning == true }

    public func ensureRuntime(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        if runtimeInstalled() { return }
        let asset = try await latestMacAsset()
        try await FileDownloader.download(from: asset.url, to: archiveURL, expected: asset.size, progress: progress)
        try unpackRuntime(from: archiveURL)
        guard runtimeInstalled() else {
            throw RouterError(AppCopy.text("localRuntime.serverMissingAfterUnpack"))
        }
    }

    public func downloadModel(_ spec: LocalModelSpec, progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        try await FileDownloader.download(from: spec.url, to: modelURL(spec), expected: spec.bytes, progress: progress)
    }

    public func start(model spec: LocalModelSpec) throws -> URL {
        if process?.isRunning == true, runningModel == spec.id {
            return serverURL
        }
        stop()
        guard runtimeInstalled() else { throw RouterError(AppCopy.text("localRuntime.installFirst")) }
        guard isInstalled(spec) else { throw RouterError(AppCopy.format("localRuntime.downloadFirst", spec.name)) }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "--model", modelURL(spec).path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(min(spec.context, 8192)),
            "--alias", spec.id,
            "--jinja",
        ]
        process.currentDirectoryURL = paths.runtime
        process.standardOutput = Pipe()
        process.standardError = Pipe()
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

    public func waitUntilReady(timeoutMs: Int = 20_000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if process?.isRunning == false { return false }
            if await ping() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await ping()
    }

    public func ping() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health")
                ?? URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<500).contains(status)
        } catch {
            return false
        }
    }

    public struct ReleaseAsset: Sendable {
        public var tag: String
        public var url: URL
        public var size: Int64
    }

    public func latestMacAsset() async throws -> ReleaseAsset {
        let url = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RouterError(AppCopy.format("localRuntime.githubReleaseFailed", status)) }
        return try Self.macAsset(from: try JSONCodec.parse(data), arch: LocalRuntime.hostArch)
    }

    public static func macAsset(from json: JSONValue, arch: String) throws -> ReleaseAsset {
        let tag = json["tag_name"]?.string ?? "latest"
        let needle = "bin-macos-\(arch)"
        guard case .array(let assets) = json["assets"] else {
            throw RouterError(AppCopy.text("localRuntime.noAssets"))
        }
        for asset in assets {
            let name = asset["name"]?.string ?? ""
            if name.contains(needle), let href = asset["browser_download_url"]?.string, let remote = URL(string: href) {
                return ReleaseAsset(tag: tag, url: remote, size: Int64(asset["size"]?.int ?? 0))
            }
        }
        throw RouterError(AppCopy.format("localRuntime.noMacBuild", arch, tag))
    }

    public static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    private func unpackRuntime(from archive: URL) throws {
        let extract = paths.runtime.appendingPathComponent("extract", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: extract)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", extract.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RouterError(AppCopy.format("localRuntime.tarFailed", process.terminationStatus))
        }
        guard let found = firstFile(named: "llama-server", under: extract) else {
            throw RouterError(AppCopy.text("localRuntime.serverMissingInArchive"))
        }
        if fm.fileExists(atPath: binaryURL.path) {
            try fm.removeItem(at: binaryURL)
        }
        try fm.copyItem(at: found, to: binaryURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        try? fm.removeItem(at: extract)
    }

    private func firstFile(named name: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in enumerator {
            if file.lastPathComponent == name { return file }
        }
        return nil
    }
}
