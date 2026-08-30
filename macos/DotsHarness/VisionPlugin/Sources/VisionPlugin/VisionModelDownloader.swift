// Copyright (c) 2026 DOTS
// Streaming, checksum-verified model download for the standalone plugin.

import CryptoKit
import Foundation

enum VisionModelDownloader {
    struct Progress: Sendable {
        let fraction: Double
    }

    static func download(
        from remote: URL,
        to destination: URL,
        expected: Int64,
        sha256: String,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isValid(destination, expected: expected, sha256: sha256) {
            progress?(Progress(fraction: 1))
            return
        }
        try? fm.removeItem(at: destination)

        let part = destination.appendingPathExtension("part")
        var request = URLRequest(url: remote, timeoutInterval: 60)
        request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw VisionModelDownloadError.http(status)
        }

        if fm.fileExists(atPath: part.path) { try fm.removeItem(at: part) }
        fm.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }

        let total = response.expectedContentLength > 0 ? response.expectedContentLength : expected
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(128 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 128 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(Progress(fraction: total > 0 ? min(1, Double(received) / Double(total)) : 0))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try Task.checkCancellation()
        try handle.close()
        guard isValid(part, expected: expected, sha256: sha256) else {
            try? fm.removeItem(at: part)
            throw VisionModelDownloadError.integrity
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
        progress?(Progress(fraction: 1))
    }

    private static func isValid(_ url: URL, expected: Int64, sha256: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size == expected,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let digest = CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest.caseInsensitiveCompare(sha256) == .orderedSame
    }
}

private enum VisionModelDownloadError: LocalizedError {
    case http(Int)
    case integrity

    var errorDescription: String? {
        switch self {
        case .http(let status): return "Vision model download failed (HTTP \(status))."
        case .integrity: return "Vision model checksum or size verification failed."
        }
    }
}
