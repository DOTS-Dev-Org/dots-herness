// Copyright (c) 2026 DOTS

import Foundation
import XCTest
@testable import DotsHarnessCore

/// Two chats of one project reaching for the same file is the case the write
/// leases exist for: the second one must wait, not overwrite.
final class WorkspaceLeaseTests: XCTestCase {
    private var workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private var root: String { workspace.standardizedFileURL.resolvingSymlinksInPath().path }

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("leases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        WorkspaceLeases.shared.releaseAll(conversationID: "alpha")
        WorkspaceLeases.shared.releaseAll(conversationID: "beta")
        WorkspaceLeases.shared.releaseAll(conversationID: "gamma")
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    private func fileTarget(_ name: String) -> WorkspaceLeaseTarget {
        .file(root: root, path: workspace.appendingPathComponent(name).path)
    }

    private func acquire(
        _ target: WorkspaceLeaseTarget,
        _ conversationID: String,
        title: String? = nil,
        tool: String = "write_file"
    ) -> WorkspaceLeaseRequest {
        WorkspaceLeases.shared.tryAcquire(
            target,
            conversationID: conversationID,
            conversationTitle: title ?? conversationID,
            runID: UUID(),
            toolName: tool,
            label: "note.txt"
        )
    }

    func testSecondChatIsContestedAndSeesWhoHoldsTheFile() {
        let target = fileTarget("note.txt")
        guard case .granted = acquire(target, "alpha") else {
            return XCTFail("The first chat must get the file it asked for.")
        }
        guard case .contested(let holder) = acquire(target, "beta") else {
            return XCTFail("The second chat must not get a file that is already held.")
        }
        XCTAssertEqual(holder.conversationID, "alpha")
        XCTAssertEqual(holder.conversationTitle, "alpha")
        XCTAssertEqual(holder.toolName, "write_file")
    }

    func testAChatNeverWaitsBehindItself() {
        let target = fileTarget("note.txt")
        guard case .granted = acquire(target, "alpha") else { return XCTFail("First request failed.") }
        if case .contested = acquire(target, "alpha") {
            XCTFail("A run that nests must not deadlock on the lease it already holds.")
        }
    }

    func testWorkspaceWideCommandCollidesWithEveryFileOfThatProject() {
        let command = WorkspaceLeaseTarget.workspace(root: root)
        let file = fileTarget("note.txt")
        guard case .granted = acquire(command, "alpha", tool: "run_command") else {
            return XCTFail("The destructive command must be able to claim the workspace.")
        }
        if case .granted = acquire(file, "beta") {
            XCTFail("A file write must not pass a command that can delete it.")
        }
        WorkspaceLeases.shared.releaseAll(conversationID: "alpha")
        guard case .granted = acquire(file, "beta") else { return XCTFail("Release must free the file.") }
        if case .granted = acquire(command, "gamma", tool: "run_command") {
            XCTFail("A workspace-wide command must not pass a file write either.")
        }
    }

    func testAnotherProjectsCommandDoesNotHoldThisProjectsFiles() {
        let elsewhere = WorkspaceLeaseTarget.workspace(root: "/tmp/another-\(UUID().uuidString)")
        guard case .granted = acquire(elsewhere, "alpha", tool: "run_command") else {
            return XCTFail("A command claims its own workspace.")
        }
        if case .contested = acquire(fileTarget("note.txt"), "beta") {
            XCTFail("Two different projects must not wait for each other.")
        }
    }

    func testAStaleReleaseCannotDropSomeoneElsesLease() {
        let target = fileTarget("note.txt")
        guard case .granted(let alphaTicket) = acquire(target, "alpha") else {
            return XCTFail("Alpha must hold the lease before it is taken away.")
        }
        WorkspaceLeases.shared.release(target: target, ticket: alphaTicket)
        guard case .granted(let betaTicket) = acquire(target, "beta") else {
            return XCTFail("Beta must be able to take the released file.")
        }
        // Alpha's late release must not free beta's lease.
        WorkspaceLeases.shared.release(target: target, ticket: alphaTicket)
        if case .granted = acquire(target, "gamma") {
            XCTFail("Beta still holds it; a third chat must not get in.")
        }
        WorkspaceLeases.shared.release(target: target, ticket: betaTicket)
    }

    func testWaitingChatWakesWhenTheHolderReleases() async throws {
        let target = fileTarget("note.txt")
        guard case .granted(let ticket) = acquire(target, "alpha") else {
            return XCTFail("Alpha must hold the lease.")
        }
        let free = Task {
            await WorkspaceLeases.shared.waitUntilFree(target, conversationID: "beta", timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(200))
        if case .granted = acquire(target, "beta") {
            XCTFail("The wait must hold while alpha is writing.")
        }
        WorkspaceLeases.shared.release(target: target, ticket: ticket)
        let arrived = await free.value
        XCTAssertTrue(arrived)
        if case .contested = acquire(target, "beta") {
            XCTFail("The file must be takeable once the wait is over.")
        }
    }

    func testWaitingChatGivesUpAtItsDeadline() async {
        let target = fileTarget("note.txt")
        guard case .granted = acquire(target, "alpha") else { return XCTFail("Alpha must hold the lease.") }
        let arrived = await WorkspaceLeases.shared.waitUntilFree(target, conversationID: "beta", timeout: 0.4)
        XCTAssertFalse(arrived, "A still-held file must not look free when the wait runs out.")
    }

    func testCancelledChatStopsWaitingImmediately() async {
        let target = fileTarget("note.txt")
        guard case .granted = acquire(target, "alpha") else { return XCTFail("Alpha must hold the lease.") }
        let started = Date()
        let arrived = await WorkspaceLeases.shared.waitUntilFree(
            target,
            conversationID: "beta",
            timeout: nil,
            isCancelled: { true }
        )
        XCTAssertFalse(arrived)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "An interrupted run must stop waiting at once.")
    }

    func testStoppingAChatWakesWhoeverWaitedForItsFile() async throws {
        let target = fileTarget("note.txt")
        guard case .granted = acquire(target, "alpha") else { return XCTFail("Alpha must hold the lease.") }
        let free = Task {
            await WorkspaceLeases.shared.waitUntilFree(target, conversationID: "beta", timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(200))
        WorkspaceLeases.shared.releaseAll(conversationID: "alpha")
        let woke = await free.value
        XCTAssertTrue(woke)
    }

    func testOnlyMutatingToolsClaimAnything() {
        let leases = WorkspaceLeases.shared
        func target(for tool: String, _ arguments: [String: Any]) -> WorkspaceLeaseTarget? {
            leases.target(for: tool, arguments: arguments, workspace: workspace)
        }
        XCTAssertNotNil(target(for: "write_file", ["path": "note.txt"]))
        XCTAssertNotNil(target(for: "remove_file", ["path": "note.txt"]))
        XCTAssertNotNil(target(for: "copy_generated_media", ["destination_path": "out.png"]))
        XCTAssertNotNil(target(for: "run_command", ["command": "git clean -fd"]))
        XCTAssertNil(target(for: "read_file", ["path": "note.txt"]))
        XCTAssertNil(target(for: "grep_files", ["pattern": "note"]))
        XCTAssertNil(target(for: "run_command", ["command": "swift test"]), "A test run must not freeze the other chats.")
        XCTAssertNil(target(for: "write_file", [:]))
    }

    func testLeasesAndReadsFollowTheSamePathAsTheWrite() throws {
        let symlink = workspace.appendingPathComponent("alias.txt")
        let real = workspace.appendingPathComponent("note.txt")
        try "first".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: real)
        let viaReal = WorkspaceLeases.shared.target(for: "write_file", arguments: ["path": "note.txt"], workspace: workspace)
        let viaAlias = WorkspaceLeases.shared.target(for: "write_file", arguments: ["path": "alias.txt"], workspace: workspace)
        guard case .file(_, let realPath) = viaReal, case .file(_, let aliasPath) = viaAlias else {
            return XCTFail("Both calls must map to a file lease.")
        }
        XCTAssertEqual(realPath, aliasPath, "A symlink must not let a second chat write the same file twice.")
    }

    func testReadsAuthorizeOnlyTheChatThatMadeThem() throws {
        let ledger = ReadLedger()
        let file = workspace.appendingPathComponent("note.txt")
        let data = try XCTUnwrap("first".data(using: .utf8))
        try data.write(to: file)

        ledger.record(file, data: data, conversationID: "alpha")
        XCTAssertEqual(ledger.state(for: file, data: data, conversationID: "alpha"), .fresh)
        XCTAssertEqual(
            ledger.state(for: file, data: data, conversationID: "beta"),
            .unread,
            "What one chat read says nothing about what another chat has seen."
        )

        ledger.record(file, data: data, conversationID: "beta")
        ledger.forgetConversation("alpha")
        XCTAssertEqual(ledger.state(for: file, data: data, conversationID: "beta"), .fresh)
        XCTAssertEqual(ledger.state(for: file, data: data, conversationID: "alpha"), .unread)
    }
}
