// Copyright (c) 2026 DOTS
// HTTP download for local runtimes and model files.

import CryptoKit
import Foundation

public enum FileDownloader {
    public struct Progress: Sendable, Equatable {
        public var received: Int64
        public var expected: Int64
        public var bytesPerSecond: Double
        public var fraction: Double {
            guard expected > 0 else { return 0 }
            return min(1, Double(received) / Double(expected))
        }

        public init(received: Int64, expected: Int64, bytesPerSecond: Double = 0) {
            self.received = received
            self.expected = expected
            self.bytesPerSecond = bytesPerSecond
        }
    }

    public static func download(
        from remote: URL,
        to destination: URL,
        expected: Int64 = 0,
        sha256: String? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            let sizeMatches = expected == 0 || size == expected
            let checksumMatches = sha256 == nil || (try? checksum(of: destination)) == normalizedChecksum(sha256)
            if sizeMatches && checksumMatches {
                progress?(Progress(received: size, expected: max(expected, size)))
                return
            }
            try? fm.removeItem(at: destination)
        }

        progress?(Progress(received: 0, expected: expected))
        var request = URLRequest(url: remote, timeoutInterval: 60)
        request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
        let part = destination.appendingPathExtension("part")
        var offset = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RouterError(AppCopy.format("download.failed", status))
        }
        let append = offset > 0 && status == 206
        if !append {
            offset = 0
            if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        }
        let expectedTotal = response.expectedContentLength > 0 ? response.expectedContentLength + offset : expected
        let transferStart = offset
        let startedAt = ProcessInfo.processInfo.systemUptime
        var lastSpeed = 0.0
        func report(_ received: Int64) {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            lastSpeed = elapsed > 0
                ? Double(max(0, received - transferStart)) / elapsed
                : 0
            progress?(Progress(received: received, expected: expectedTotal, bytesPerSecond: lastSpeed))
        }
        report(offset)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        if append { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
        var received = offset
        var buffer = Data()
        buffer.reserveCapacity(128 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 128 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                report(received)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        report(received)
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? received
        guard expected == 0 || size == expected else {
            try? fm.removeItem(at: destination)
            throw RouterError(AppCopy.text("download.sizeMismatch"))
        }
        if let sha256, (try checksum(of: destination)) != normalizedChecksum(sha256) {
            try? fm.removeItem(at: destination)
            throw RouterError(AppCopy.text("download.checksumMismatch"))
        }
        progress?(Progress(received: size, expected: max(expected, size), bytesPerSecond: lastSpeed))
    }

    private static func checksum(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedChecksum(_ value: String?) -> String? {
        value?.replacingOccurrences(of: "sha256:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
