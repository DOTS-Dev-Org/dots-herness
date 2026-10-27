// Copyright (c) 2026 DOTS

import XCTest
import Foundation
@testable import DotsHarnessCore

/// Same cases as shared/ProjectMapTests.cs, so both platforms draw the same map.
final class ProjectMapTests: XCTestCase {
    func testMapNamesEachFolderWithCountPurposeAndEntryFiles() {
        let files = [
            "README.md", "api/README.md", "api/src/server.ts", "api/src/routes.ts", "api/package.json",
            "app/Package.swift", "app/Sources/App/main.swift", "app/Sources/App/View.swift", "tools/a.py",
        ]
        let reads = [
            "api/README.md": "# API\n\n[![badge](x)](y)\nThe HTTP backend that stores accounts.\n",
            "api/package.json": #"{ "name": "api", "description": "ignored when a README says it" }"#,
        ]
        let map = ProjectMap.markdown(files) { reads[$0] }

        XCTAssertTrue(map.contains("- root - open: README.md"))
        XCTAssertTrue(map.contains("- `api/` - The HTTP backend that stores accounts. - open: README.md, package.json"))
        XCTAssertTrue(map.contains("  - `api/src/` - mostly .ts - open: server.ts"))
        XCTAssertTrue(map.contains("- `app/` - Swift package, mostly .swift - open: Package.swift"))
        XCTAssertTrue(map.contains("  - `app/Sources/` - mostly .swift"))
        XCTAssertTrue(map.contains("- `tools/` - mostly .py"))
        XCTAssertEqual(ProjectMap.markdown(["README.md"]) { _ in nil }, "")
    }

    func testSearchFollowsGitignoreAndSkipsHerNessCaches() throws {
        // Resolved: /var is a link to /private/var, and the tools refuse a path that leaves the workspace.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ProjectMapTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(".gitignore", "generated/\n")
        try write("src/a.swift", "needle")
        try write("generated/b.swift", "needle")
        try write(".sandbox-cache/c.swift", "needle")
        _ = WorkspaceMemory.gitLines(["init", "-q"], workspace: root)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path), "no git here")

        let found = WorkspaceTools.execute(
            AgentToolCall(id: "1", name: "grep_files", arguments: #"{"pattern":"needle"}"#),
            workspace: root, conversationID: "map-test")

        XCTAssertTrue(found.contains("src/a.swift:1:needle"), found)
        XCTAssertFalse(found.contains("generated/"), found)
        XCTAssertFalse(found.contains(".sandbox-cache"), found)
        XCTAssertEqual(ProjectMap.files(in: root).sorted(), [".gitignore", "src/a.swift"])
    }
}
