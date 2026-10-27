// Copyright (c) 2026 DOTS

import XCTest
import Foundation
@testable import DotsHarnessCore

final class ScanPathCoalescingTests: XCTestCase {
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var scans = 0
        private var results: [[String]] = []
        func scanned() { lock.withLock { scans += 1 } }
        func got(_ paths: [String]) { lock.withLock { results.append(paths) } }
        var snapshot: (scans: Int, results: [[String]]) { lock.withLock { (scans, results) } }
    }

    func testConcurrentScansOfOneRootRunOnce() {
        let cache = WorkspaceTools.ScanPathCache()
        let tally = Tally()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            tally.got(cache.paths(for: "/repo") {
                tally.scanned()
                Thread.sleep(forTimeInterval: 0.2)
                return ["a.swift"]
            })
        }
        XCTAssertEqual(tally.snapshot.scans, 1)
        XCTAssertEqual(tally.snapshot.results, Array(repeating: ["a.swift"], count: 8))
        _ = cache.paths(for: "/other") { tally.scanned(); return [] }
        XCTAssertEqual(tally.snapshot.scans, 2, "another root scans on its own")
    }

    /// The list is reused for seconds, but the agent's own write drops it, and a scan that
    /// a write raced is not kept for later callers.
    func testAWriteDropsTheReusedList() {
        let cache = WorkspaceTools.ScanPathCache()
        XCTAssertEqual(cache.paths(for: "/repo") { ["a.swift"] }, ["a.swift"])
        XCTAssertEqual(cache.paths(for: "/repo") { ["unused"] }, ["a.swift"])
        cache.invalidate()
        XCTAssertEqual(cache.paths(for: "/repo") { cache.invalidate(); return ["raced"] }, ["raced"])
        XCTAssertEqual(cache.paths(for: "/repo") { ["b.swift"] }, ["b.swift"])
        XCTAssertEqual(cache.paths(for: "/repo") { ["unused"] }, ["b.swift"])
    }
}
