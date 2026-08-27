// Copyright (c) 2026 DOTS
// Explicitly downloaded, checksum-pinned Quick Tunnel process.

import Foundation

@MainActor
public final class CloudTunnelProcess {
    private let runtimeURL: URL
    private var process: Process?
    private var outputPipe: Pipe?

    public init(runtimeURL: URL) {
        self.runtimeURL = runtimeURL
    }

    public func start(
        gatewayPort: Int,
        progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil
    ) async throws -> String {
        stop()
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        let asset = try Self.asset()
        let archive = runtimeURL.appendingPathComponent(asset.fileName)
        try await FileDownloader.download(from: asset.url, to: archive, sha256: asset.sha256, progress: progress)

        let extractURL = runtimeURL.appendingPathComponent("cloudflared-extract", isDirectory: true)
        try? FileManager.default.removeItem(at: extractURL)
        try FileManager.default.createDirectory(at: extractURL, withIntermediateDirectories: true)
        let extractor = Process()
        extractor.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extractor.arguments = ["-xzf", archive.path, "-C", extractURL.path]
        try extractor.run()
        extractor.waitUntilExit()
        guard extractor.terminationStatus == 0 else {
            throw RouterTestError.message("The sharing binary archive could not be unpacked.")
        }
        guard let found = Self.firstFile(named: "cloudflared", under: extractURL) else {
            throw RouterTestError.message("The sharing binary was not found in the verified archive.")
        }
        let binary = runtimeURL.appendingPathComponent("cloudflared")
        if FileManager.default.fileExists(atPath: binary.path) { try FileManager.default.removeItem(at: binary) }
        try FileManager.default.copyItem(at: found, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let output = OutputBuffer()
        let pipe = Pipe()
        let running = Process()
        running.executableURL = binary
        running.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:" + String(gatewayPort)]
        running.standardOutput = pipe
        running.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(String(data: data, encoding: .utf8) ?? "") }
        }
        try running.run()
        process = running
        outputPipe = pipe

        let deadline = Date().addingTimeInterval(45)
        while running.isRunning && Date() < deadline {
            if let url = output.publicURL() { return url }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let url = output.publicURL() { return url }
        stop()
        throw RouterTestError.message("The sharing process did not produce a public URL in time.")
    }

    public func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        guard let process else { return }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        self.process = nil
    }

    private static func asset() throws -> Asset {
        #if arch(arm64)
        return Asset(
            fileName: "cloudflared-darwin-arm64.tgz",
            url: URL(string: "https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-darwin-arm64.tgz")!,
            sha256: "cd9f764abfd06757b4def10ee5ba3d862381ed9fc02d6c1f06086c23d88695c6"
        )
        #elseif arch(x86_64)
        return Asset(
            fileName: "cloudflared-darwin-amd64.tgz",
            url: URL(string: "https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-darwin-amd64.tgz")!,
            sha256: "c4fdc6021cd63003e32e70b577e17d47d493c6df4e24c7c97169ed74b67a715d"
        )
        #else
        throw RouterTestError.message("Sharing is not available for this Mac architecture.")
        #endif
    }

    private static func firstFile(named name: String, under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return enumerator?.compactMap { $0 as? URL }.first { $0.lastPathComponent == name }
    }

    private struct Asset {
        var fileName: String
        var url: URL
        var sha256: String
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            text.append(value)
        }

        func publicURL() -> String? {
            lock.lock(); defer { lock.unlock() }
            for token in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>,\"'"))
                if candidate.hasPrefix("https://"), candidate.contains(".trycloudflare.com") { return candidate }
            }
            return nil
        }
    }
}
