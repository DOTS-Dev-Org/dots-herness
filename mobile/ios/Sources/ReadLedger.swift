import CryptoKit
import Foundation

// ponytail: global ledger (512 cap) — cross-conversation reuse can allow blind write without re-read; per-conversation ledger if that matters.
/// Remembers the content hash of every file the agent has fully read, so
/// `write_file` can tell an informed rewrite from a blind one. Session-scoped and
/// bounded; forgetting an entry only costs one extra read.
/// Ported from `macos/DotsHarness/Sources/DotsHarnessCore/WorkspaceTools.swift:505`
final class ReadLedger: @unchecked Sendable {
    enum State { case fresh, stale, unread }

    static let shared = ReadLedger()
    private let lock = NSLock()
    private var hashes: [String: String] = [:]
    private var order: [String] = []
    private let capacity = 512

    func record(_ file: URL, data: Data) {
        let key = file.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = Self.hash(data)
        lock.lock(); defer { lock.unlock() }
        if hashes[key] == nil { order.append(key) }
        hashes[key] = hash
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            hashes[oldest] = nil
        }
    }

    func forget(_ file: URL) {
        let key = file.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock(); defer { lock.unlock() }
        if hashes.removeValue(forKey: key) != nil { order.removeAll { $0 == key } }
    }

    func state(for file: URL, data: Data) -> State {
        let key = file.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock()
        let known = hashes[key]
        lock.unlock()
        guard let known else { return .unread }
        return known == Self.hash(data) ? .fresh : .stale
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        hashes.removeAll()
        order.removeAll()
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
