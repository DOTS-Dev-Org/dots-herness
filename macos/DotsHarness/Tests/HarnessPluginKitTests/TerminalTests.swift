// Copyright (c) 2026 DOTS

import Foundation
import XCTest
@testable import DotsHarnessCore

@MainActor
final class TerminalTests: XCTestCase {
    func testTerminalRunsCommandsInItsProjectDirectory() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("dots-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let session = TerminalSession(workspacePath: project.path)
        session.start()
        defer { session.stop() }

        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(waitForOutput(session, containing: "%"), session.output)
        session.send("pwd")
        XCTAssertTrue(waitForOutput(session, containing: project.path), session.output)

        session.send("test -t 0 && printf 'tty-ok\\n'")
        XCTAssertTrue(waitForOutput(session, containing: "tty-ok"), session.output)

        session.send("printf 'terminal-command-ok\\n'")
        XCTAssertTrue(waitForOutput(session, containing: "terminal-command-ok"), session.output)

        session.sendInput("echo terminal-raw-input-ok\u{000d}")
        XCTAssertTrue(waitForOutput(session, containing: "terminal-raw-input-ok"), session.output)
    }

    func testTerminalManagerSharesOnlyTheCurrentProjectSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dots-terminal-manager-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TerminalManager()
        defer { manager.stopAll() }

        let firstTerminal = try XCTUnwrap(manager.openSession(for: first.path))
        let secondTerminal = try XCTUnwrap(manager.openSession(for: first.path))
        let otherProjectTerminal = try XCTUnwrap(manager.openSession(for: second.path))

        XCTAssertEqual(manager.sessions(for: first.path).map(\.id), [firstTerminal.id, secondTerminal.id])
        XCTAssertEqual(manager.sessions(for: second.path).map(\.id), [otherProjectTerminal.id])
        XCTAssertTrue(manager.selectedSession(for: first.path)?.id == secondTerminal.id)
        XCTAssertFalse(manager.sessions(for: second.path).contains { $0.id == firstTerminal.id })

        manager.closeSession(secondTerminal, for: first.path)
        XCTAssertEqual(manager.sessions(for: first.path).map(\.id), [firstTerminal.id])
    }

    private func waitForOutput(_ session: TerminalSession, containing value: String) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if session.output.contains(value) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return session.output.contains(value)
    }
}
