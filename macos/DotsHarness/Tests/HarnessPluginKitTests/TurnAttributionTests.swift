import XCTest
@testable import DotsHarnessCore

final class TurnAttributionTests: XCTestCase {
    func testOnlyFilesTouchedWhileACommandRanAreAttributed() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("x".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        let file = ChangedFile(path: "a.txt", operation: .modified, addedLines: 1, deletedLines: 0, preview: nil)
        let gone = ChangedFile(path: "gone.txt", operation: .deleted, addedLines: 0, deletedLines: 1, preview: nil)
        let now = Date()

        let during = [(start: now.addingTimeInterval(-5), end: Optional(now.addingTimeInterval(5)))]
        XCTAssertTrue(AgentBridge.changed(file, workspace: workspace, during: during))
        XCTAssertTrue(AgentBridge.changed(gone, workspace: workspace, during: during))

        // A read-only command that finished long before another program wrote the file.
        let earlier = [(start: now.addingTimeInterval(-60), end: Optional(now.addingTimeInterval(-50)))]
        XCTAssertFalse(AgentBridge.changed(file, workspace: workspace, during: earlier))
        XCTAssertFalse(AgentBridge.changed(gone, workspace: workspace, during: earlier))

        // A terminal session never closes its window.
        let open: [(start: Date, end: Date?)] = [(start: now.addingTimeInterval(-60), end: nil)]
        XCTAssertTrue(AgentBridge.changed(file, workspace: workspace, during: open))
    }
}
