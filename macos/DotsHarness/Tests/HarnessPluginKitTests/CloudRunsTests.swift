// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessCore

final class CloudRunsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudRunsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRemoteURLsReduceToHostAndPath() {
        let expected = GitRemote(url: "https://github.com/octo/hello")
        XCTAssertEqual(expected?.host, "github.com")
        XCTAssertEqual(expected?.path, "octo/hello")
        for url in [
            "https://github.com/octo/hello.git",
            "git@github.com:octo/hello.git",
            "ssh://git@github.com:22/octo/hello.git",
            "https://token@github.com/octo/hello/",
        ] {
            XCTAssertEqual(GitRemote(url: url), expected, url)
        }
        XCTAssertNil(GitRemote(url: "/srv/git/hello.git"))
    }

    func testOnlyGitHubDotComRepositoriesCanRunInTheCloud() {
        XCTAssertEqual(GitHubRepository(remote: GitRemote(url: "git@github.com:octo/hello.git")!)?.fullName, "octo/hello")
        XCTAssertNil(GitHubRepository(remote: GitRemote(url: "https://gitlab.com/octo/hello")!))
        XCTAssertNil(GitHubRepository(remote: GitRemote(url: "https://github.com/octo/hello/tree/main")!))
        XCTAssertNil(GitHubRepository(fullName: "octo/hel lo"))
    }

    func testRepositoryAndBranchComeFromTheCheckoutFiles() throws {
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try """
        [core]
        \tbare = false
        [remote "origin"]
        \turl = git@github.com:octo/hello.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """.write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/cloud\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitHubRepository(workspacePath: root.path)?.fullName, "octo/hello")
        XCTAssertEqual(GitRemote.currentBranch(atRepository: root.path), "feature/cloud")

        try "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertNil(GitRemote.currentBranch(atRepository: root.path))
    }

    func testWorktreeCheckoutsReadTheSharedConfig() throws {
        let main = root.appendingPathComponent("main/.git")
        let worktreeGit = main.appendingPathComponent("worktrees/side")
        let worktree = root.appendingPathComponent("side")
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = https://github.com/octo/hello.git\n".write(to: main.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: worktreeGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/side\n".write(to: worktreeGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(worktreeGit.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitHubRepository(workspacePath: worktree.path)?.fullName, "octo/hello")
        XCTAssertEqual(GitRemote.currentBranch(atRepository: worktree.path), "side")
    }

    func testRunDecodesTheWorkerPayload() throws {
        let json = """
        {"run":{"id":"6f1c2a9e-4b7d-4e2a-9c1f-0a1b2c3d4e5f","repository":"octo/hello","base_ref":"main","prompt":"Fix the build",
        "model":null,"status":"running","cancel_requested":false,"github_run_id":"42","github_run_url":"https://github.com/octo/hello/actions/runs/42",
        "result_branch":null,"result_commit":null,"summary":null,"error":null,"event_count":3,
        "created_at":"2026-10-27T17:13:19.444Z","updated_at":"2026-10-27T17:13:19.444Z","started_at":null,"finished_at":null},
        "events":[{"seq":1,"kind":"status","text":"Runner started.","tool":null,"created_at":"2026-10-27T17:13:20.000Z"}]}
        """
        struct Envelope: Decodable { let run: CloudRun; let events: [CloudRunEvent] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.run.status, .running)
        XCTAssertTrue(envelope.run.status.isActive)
        XCTAssertEqual(envelope.run.githubRunID, "42")
        XCTAssertNotNil(envelope.run.createdDate)
        XCTAssertEqual(envelope.events.map(\.text), ["Runner started."])
    }

    func testBundledWorkflowIsTheCloudWorkflow() throws {
        let template = try XCTUnwrap(CloudWorkflow.template())
        XCTAssertTrue(template.contains("workflow_dispatch:"))
        XCTAssertTrue(template.contains("id-token: write"))
        XCTAssertTrue(template.contains("HERNESS_API_KEY"))
    }
}
