import XCTest
@testable import DotsHarnessCore

final class ProjectRulesTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProjectRulesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = workspace.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReadsKnownRulesFilesAndLabelsThem() throws {
        try write("AGENTS.md", "use tabs")
        try write(".cursor/rules/style.mdc", "no semicolons")

        let text = ProjectRules.text(workspace: workspace)

        XCTAssertTrue(text.contains("# AGENTS.md\nuse tabs"))
        XCTAssertTrue(text.contains("# .cursor/rules/style.mdc\nno semicolons"))
        // AGENTS.md is the general file, so it leads.
        XCTAssertTrue(text.hasPrefix("# AGENTS.md"))
    }

    func testNewerRulesFileIsMirroredOntoTheOtherAndEmittedOnce() throws {
        try write("CLAUDE.md", "stale")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-300)],
            ofItemAtPath: workspace.appendingPathComponent("CLAUDE.md").path
        )
        try write("AGENTS.md", "use tabs")

        let text = ProjectRules.text(workspace: workspace)

        let mirrored = try String(contentsOf: workspace.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        XCTAssertEqual(mirrored, "use tabs")
        XCTAssertEqual(text, "# AGENTS.md\nuse tabs")
    }

    func testMissingCounterpartIsCreated() throws {
        try write("CLAUDE.md", "run make test")
        ProjectRules.sync(workspace: workspace)
        let created = try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertEqual(created, "run make test")
    }

    func testEmptyWorkspaceIsSeededWithBothRulesFiles() throws {
        XCTAssertTrue(ProjectRules.seedIfMissing(workspace: workspace))

        for name in ["AGENTS.md", "CLAUDE.md"] {
            XCTAssertEqual(
                try String(contentsOf: workspace.appendingPathComponent(name), encoding: .utf8),
                ProjectRules.seed
            )
        }
        XCTAssertEqual(ProjectRules.text(workspace: workspace), "# AGENTS.md\n" + ProjectRules.seed)
    }

    func testSeedLeavesAProjectThatAlreadyHasEitherFileAlone() throws {
        try write("CLAUDE.md", "run make test")
        XCTAssertFalse(ProjectRules.seedIfMissing(workspace: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("AGENTS.md").path))
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("CLAUDE.md"), encoding: .utf8),
            "run make test"
        )
    }

    func testTextNeverSeeds() throws {
        XCTAssertEqual(ProjectRules.text(workspace: workspace), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("AGENTS.md").path))
    }

    func testNoWorkspaceAndBlankRulesFileYieldNothing() throws {
        XCTAssertEqual(ProjectRules.text(workspace: nil), "")
        try write("AGENTS.md", "   \n  ")
        XCTAssertEqual(ProjectRules.text(workspace: workspace), "")
    }

    func testOversizedFileIsTruncated() throws {
        try write("AGENTS.md", String(repeating: "x", count: ProjectRules.maxBytesPerFile * 2))
        let text = ProjectRules.text(workspace: workspace)
        XCTAssertTrue(text.hasSuffix("… truncated"))
        XCTAssertLessThan(text.utf8.count, ProjectRules.maxBytesPerFile + 200)
    }

    func testSymlinkEscapingTheWorkspaceIsIgnored() throws {
        let outside = workspace.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        try "secret rules".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("AGENTS.md"),
            withDestinationURL: outside
        )

        XCTAssertEqual(ProjectRules.text(workspace: workspace), "")
    }
}
