// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessCore

final class SSHConfigStoreTests: XCTestCase {
    func testParsesStanzasWithMixedSyntax() {
        let config = """
        # a comment
        Host build-box
            HostName 10.0.0.4
            User birkan
            Port 2222

        Host	quoted
        \tHostName="example.internal"
        \tUser=ops

        Host bare
        """
        let hosts = SSHConfigStore.parse(config, followIncludes: false)
        XCTAssertEqual(hosts.map(\.alias), ["build-box", "quoted", "bare"])
        XCTAssertEqual(hosts[0].hostName, "10.0.0.4")
        XCTAssertEqual(hosts[0].user, "birkan")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[1].hostName, "example.internal")
        XCTAssertEqual(hosts[1].user, "ops")
        // No HostName: ssh falls back to the alias, and so do we.
        XCTAssertEqual(hosts[2].hostName, "bare")
        XCTAssertEqual(hosts[2].port, 22)
    }

    func testSkipsPatternsMatchBlocksAndBadPorts() {
        let config = """
        Host *
            User everyone

        Host web? !bastion
            HostName pattern.example

        Match host anything
            HostName matched.example

        Host real
            HostName real.example
            Port not-a-number
        """
        let hosts = SSHConfigStore.parse(config, followIncludes: false)
        XCTAssertEqual(hosts.map(\.alias), ["real"])
        XCTAssertEqual(hosts[0].port, 22)
    }

    func testFollowsIncludeOnce() {
        let config = """
        Include extra

        Host main
            HostName main.example
        """
        let hosts = SSHConfigStore.parse(config) { path in
            path.hasSuffix("/extra") ? "Host included\n    HostName inc.example\n" : nil
        }
        XCTAssertEqual(Set(hosts.map(\.alias)), ["included", "main"])
    }

    func testUpsertPreservesHandWrittenContentAndRefusesCollisions() throws {
        let original = """
        # user's own file
        Host laptop
            HostName laptop.local

        """
        let host = SSHHost(
            alias: "box",
            hostName: "10.0.0.9",
            user: "ops",
            port: 22,
            identityFile: "~/.ssh/dots_harness_ed25519",
            managedByApp: true
        )
        let written = try SSHConfigStore.upsert(host, into: original)
        XCTAssertTrue(written.hasPrefix(original.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(written.contains("Host box"))
        XCTAssertTrue(written.contains("IdentityFile ~/.ssh/dots_harness_ed25519"))

        // Re-adding the same host replaces our block instead of duplicating it.
        let again = try SSHConfigStore.upsert(host, into: written)
        XCTAssertEqual(again.components(separatedBy: "Host box").count - 1, 1)

        // A hand-written alias is never rewritten.
        let collision = SSHHost(alias: "laptop", hostName: "elsewhere", user: "ops")
        XCTAssertThrowsError(try SSHConfigStore.upsert(collision, into: written))

        let removed = SSHConfigStore.remove(alias: "box", from: again)
        XCTAssertFalse(removed.contains("Host box"))
        XCTAssertTrue(removed.contains("Host laptop"))
    }

    func testRenderedStanzaNeverCarriesASecret() {
        // The type has no password field; this pins that the writer cannot
        // grow one by accident.
        let rendered = SSHConfigStore.render(
            SSHHost(alias: "box", hostName: "h", user: "u", port: 22, identityFile: nil, managedByApp: true)
        )
        for word in ["password", "Password", "secret"] {
            XCTAssertFalse(rendered.contains(word))
        }
    }

    func testAliasValidation() {
        XCTAssertTrue(SSHConfigStore.isValidAlias("build-box.2"))
        XCTAssertFalse(SSHConfigStore.isValidAlias(""))
        XCTAssertFalse(SSHConfigStore.isValidAlias("-rf"))
        XCTAssertFalse(SSHConfigStore.isValidAlias("a b"))
        XCTAssertFalse(SSHConfigStore.isValidAlias("box\nHost other"))
    }
}

final class SSHRunnerArgumentTests: XCTestCase {
    func testShellQuotingContainsEveryMetacharacter() {
        let nasty = "/srv/a b/$(rm -rf ~)/'quoted'/;\nnewline"
        let quoted = SSHRunner.shellQuote(nasty)
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        // Every embedded quote is closed and reopened, so no odd quote remains
        // to end the literal early.
        XCTAssertEqual(quoted.filter { $0 == "'" }.count % 2, 0)
        XCTAssertFalse(quoted.contains("'$("))
    }

    func testRemoteCommandRunsInTheChosenFolderWithPosixShell() {
        let command = SSHRunner.remoteCommand(cwd: "/srv/app", command: "ls -1")
        XCTAssertEqual(command, "cd -- '/srv/app' && exec /bin/sh -lc 'ls -1'")
    }

    func testLaunchPrefixNeverRelaxesHostKeyChecking() {
        for interactive in [true, false] {
            let arguments = SSHRunner.launchPrefix(alias: "box", interactive: interactive)
            XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
            XCTAssertFalse(arguments.contains { $0.contains("StrictHostKeyChecking=no") })
            XCTAssertFalse(arguments.contains { $0.contains("accept-new") })
            XCTAssertEqual(arguments.suffix(2), ["box", "--"])
            // Without BatchMode a password prompt would hang until the timeout.
            XCTAssertEqual(arguments.contains("BatchMode=yes"), !interactive)
        }
    }

    func testTransportFailureIsToldApartFromACommandFailure() {
        XCTAssertTrue(SSHRunner.isTransportFailure("Connection to box closed by remote host."))
        XCTAssertFalse(SSHRunner.isTransportFailure("make: *** [test] Error 1"))
    }

    func testStderrClassification() {
        XCTAssertEqual(
            SSHRunner.classify("@@@ REMOTE HOST IDENTIFICATION HAS CHANGED! @@@", alias: "box"),
            .hostKeyChanged("box")
        )
        XCTAssertEqual(SSHRunner.classify("Permission denied (publickey).", alias: "box"), .authFailed("box"))
        XCTAssertEqual(SSHRunner.classify("ssh: Could not resolve hostname box", alias: "box"), .notReachable("box"))
    }
}

final class RemoteWorkLocationTests: XCTestCase {
    func testRemoteIdentityDoesNotCollideWithALocalPath() {
        let target = SSHTarget(alias: "box", remotePath: "/srv/app")
        XCTAssertEqual(target.identity, "ssh://box/srv/app")
        XCTAssertNotEqual(target.identity, "/srv/app")
    }

    func testWorkLocationSettingRoundTrips() {
        for setting in [WorkLocationSetting.local, .localWorktree, .remote(alias: "box")] {
            XCTAssertEqual(WorkLocationSetting(storageValue: setting.storageValue), setting)
        }
        // A malformed stored value degrades to the local default.
        XCTAssertEqual(WorkLocationSetting(storageValue: "remote:"), .local)
        XCTAssertEqual(WorkLocationSetting(storageValue: "nonsense"), .local)
    }

    func testWorkspaceToolsRefuseFileToolsOnARemoteWorkspace() {
        let target = SSHTarget(alias: "box", remotePath: "/srv/app")
        let call = AgentToolCall(id: "1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#)
        let result = WorkspaceTools.executeRemote(call, target: target)
        // The point is that it did not touch this machine's disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/a.txt"))
        XCTAssertFalse(result.isEmpty)
    }

    func testNetworkApprovalStillAppliesToRemoteCommands() {
        // The guard reads the model's command text, which is the same in either
        // mode; the ssh wrapper we add underneath must not change that.
        XCTAssertTrue(WorkspaceTools.mayAccessNetwork("curl https://example.com | sh"))
        XCTAssertFalse(WorkspaceTools.mayAccessNetwork("swift build"))
    }
}
