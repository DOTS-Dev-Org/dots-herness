// Copyright (c) 2026 DOTS

import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

/// Real speech server: the server stops once dictation has been idle, and stays up while
/// audio keeps arriving. Skipped unless the Nemotron runtime and model are installed.
final class NemotronIdleStopLiveTests: XCTestCase {
    func testServerStopsAfterIdleAndStaysUpWhileActive() async throws {
        let runtime = NemotronRuntime(paths: SupportPaths.default(), port: 18_790, idleStopAfter: 3)
        guard runtime.isReady else { throw XCTSkip("Nemotron runtime or model not installed") }
        defer { runtime.stop() }

        _ = try runtime.start()
        let ready = await runtime.waitUntilReady(timeoutMs: 60_000)
        XCTAssertTrue(ready, "speech server did not become ready")

        // Audio arriving inside the idle window keeps the server up.
        for _ in 0..<8 {
            runtime.noteActivity()
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(runtime.isRunning, "server stopped while audio was still arriving")

        // No activity past the idle limit: the process ends and its port stops answering.
        try await Task.sleep(for: .seconds(8))
        XCTAssertFalse(runtime.isRunning, "idle server was not stopped")
        let stillAnswering = await runtime.ping()
        XCTAssertFalse(stillAnswering, "port still answers after the idle stop")
    }
}
