// Copyright (c) 2026 DOTS

import Foundation
import XCTest
@testable import DotsHarnessCore

/// The speech server must not outlive the app that started it.
final class SpeechServerGuardTests: XCTestCase {
    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    /// Starts `sleep` through the supervisor with a stand-in "app" as its parent.
    private func launch(parent: Int32) throws -> (guardProcess: Process, serverPID: Int32) {
        let (executable, arguments) = NemotronRuntime.guardedLaunch(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["300"],
            parentPID: parent
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        try process.run()
        // The supervisor's only child is the server.
        var pid: Int32 = 0
        XCTAssertTrue(waitUntil(3) {
            let list = Process()
            let out = Pipe()
            list.executableURL = URL(fileURLWithPath: "/bin/ps")
            list.arguments = ["-axo", "pid=,ppid=,command="]
            list.standardOutput = out
            try? list.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            list.waitUntilExit()
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if f.count == 3, Int32(f[1]) == process.processIdentifier, f[2].hasPrefix("/bin/sleep 300"), let p = Int32(f[0]) {
                    pid = p
                    return true
                }
            }
            return false
        })
        return (process, pid)
    }

    func testServerStopsWhenItsParentDies() throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["300"]
        try parent.run()

        let (supervisor, server) = try launch(parent: parent.processIdentifier)
        defer { supervisor.terminate(); kill(server, SIGKILL) }
        XCTAssertGreaterThan(server, 0)
        XCTAssertTrue(isAlive(server))

        parent.terminate()          // the "app" is killed
        parent.waitUntilExit()
        XCTAssertTrue(waitUntil(4) { !isAlive(server) }, "server outlived its parent")
        supervisor.waitUntilExit()
    }

    func testStoppingTheSupervisorStopsTheServer() throws {
        let (supervisor, server) = try launch(parent: getpid())
        defer { kill(server, SIGKILL) }
        XCTAssertTrue(isAlive(server))
        supervisor.terminate()      // what NemotronRuntime.stop() does
        supervisor.waitUntilExit()
        XCTAssertTrue(waitUntil(2) { !isAlive(server) }, "server survived stop()")
    }
}
