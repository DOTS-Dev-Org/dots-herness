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
    /// Set around a subagent's tool calls. A file the subagent read is not one the
    /// conversation saw, and the other way round, so each keeps its own entries and
    /// neither can rewrite a file on the strength of the other's read.
    @TaskLocal static var scope: String?

    private static func key(_ file: URL) -> String {
        (scope.map { $0 + "\n" } ?? "") + file.standardizedFileURL.resolvingSymlinksInPath().path
    }
    private let lock = NSLock()
    private var hashes: [String: String] = [:]
    private struct PageRead {
        let hash: String
        var lines = IndexSet()
    }
    private var pages: [String: PageRead] = [:]
    private var order: [String] = []
    private let capacity = 512

    func recordLines(_ file: URL, data: Data, lines: Range<Int>, totalLines: Int) {
        guard !lines.isEmpty else { return }
        let key = Self.key(file)
        let hash = Self.hash(data)
        lock.lock(); defer { lock.unlock() }
        if hashes[key] == hash { return }
        if !order.contains(key) { order.append(key) }
        hashes[key] = nil
        var page = pages[key].flatMap { $0.hash == hash ? $0 : nil } ?? PageRead(hash: hash)
        page.lines.insert(integersIn: lines)
        if page.lines.contains(integersIn: 1..<(totalLines + 1)) {
            hashes[key] = hash
            pages[key] = nil
        } else { pages[key] = page }
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            hashes[oldest] = nil
            pages[oldest] = nil
        }
    }

    func record(_ file: URL, data: Data) {
        let key = Self.key(file)
        let hash = Self.hash(data)
        lock.lock(); defer { lock.unlock() }
        if !order.contains(key) { order.append(key) }
        hashes[key] = hash
        pages[key] = nil
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            hashes[oldest] = nil
            pages[oldest] = nil
        }
    }

    func forget(_ file: URL) {
        let key = Self.key(file)
        lock.lock(); defer { lock.unlock() }
        hashes.removeValue(forKey: key)
        pages.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    /// Lines (1-based) read from exactly this version. A complete read covers the
    /// whole file. Stale when an older version was read; unread when nothing was.
    func coverage(for file: URL, data: Data, totalLines: Int) -> (state: State, lines: IndexSet) {
        let key = Self.key(file)
        let hash = Self.hash(data)
        lock.lock(); defer { lock.unlock() }
        if let known = hashes[key] {
            return known == hash ? (.fresh, IndexSet(integersIn: 1..<(totalLines + 1))) : (.stale, IndexSet())
        }
        if let page = pages[key] {
            return page.hash == hash ? (.fresh, page.lines) : (.stale, IndexSet())
        }
        return (.unread, IndexSet())
    }

    func state(for file: URL, data: Data, partial: Bool = false) -> State {
        let key = Self.key(file)
        lock.lock()
        let known = hashes[key] ?? (partial ? pages[key]?.hash : nil)
        lock.unlock()
        guard let known else { return .unread }
        return known == Self.hash(data) ? .fresh : .stale
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        hashes.removeAll()
        pages.removeAll()
        order.removeAll()
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
