import XCTest
import Foundation
import PluginRuntime
@testable import DotsHarnessCore

final class HerNessPromptTests: XCTestCase {
    func testUntrustedSectionsAreTaggedAndCoreIsNot() {
        let text = HerNessPrompt.assemble([
            PromptSection(tag: "core_policy", trust: .core, text: "policy"),
            PromptSection(tag: "project_memory", trust: .data, text: "memory"),
            PromptSection(tag: "plugin_guidance", trust: .untrusted, text: "plugin"),
            PromptSection(tag: "skill_metadata", trust: .untrusted, text: "   "),
        ])

        XCTAssertTrue(text.contains("<core_policy>\npolicy\n</core_policy>"))
        XCTAssertTrue(text.contains("<project_memory trust=\"data\">\nmemory\n</project_memory>"))
        XCTAssertTrue(text.contains("<plugin_guidance trust=\"untrusted\">\nplugin\n</plugin_guidance>"))
        // A blank section must not emit an empty tag pair.
        XCTAssertFalse(text.contains("skill_metadata"))
    }

    func testReportMasksCredentialsAndCountsSections() {
        let report = HerNessPrompt.report([
            PromptSection(tag: "core_policy", trust: .core, text: "policy"),
            PromptSection(
                tag: "plugin_guidance",
                trust: .untrusted,
                text: "use sk-abcdefghijklmnopqrstuvwxyz and api_key = hunter2secretvalue"
            ),
        ])

        XCTAssertFalse(report.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(report.contains("hunter2secretvalue"))
        XCTAssertTrue(report.contains("[redacted]"))
        XCTAssertTrue(report.contains("trust=untrusted"))
        XCTAssertTrue(report.contains("── total ·"))
    }

    func testMaskingNeverTouchesThePromptSentToTheModel() {
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz012345"
        let assembled = HerNessPrompt.assemble([
            PromptSection(tag: "plugin_guidance", trust: .untrusted, text: secret)
        ])
        XCTAssertTrue(assembled.contains(secret))
    }

    @MainActor
    func testSelfVerificationSectionFollowsTheToggleAndTheMode() {
        let host = NativeAgentHost(paths: temporaryPaths(), endpoint: AgentEndpointController())
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())

        func text(workspace: URL?, planMode: Bool) -> String {
            HerNessPrompt.assemble(host.systemPromptSections(workspace: workspace, planMode: planMode))
        }

        XCTAssertTrue(text(workspace: workspace, planMode: false).contains("Self-verification"))
        XCTAssertFalse(text(workspace: workspace, planMode: true).contains("Self-verification"))
        XCTAssertFalse(text(workspace: nil, planMode: false).contains("Self-verification"))

        host.setSelfVerification(false)
        XCTAssertFalse(text(workspace: workspace, planMode: false).contains("Self-verification"))
    }

    @MainActor
    func testMemoryGuidanceFollowsTheWorkspace() {
        let host = NativeAgentHost(paths: temporaryPaths(), endpoint: AgentEndpointController())
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())

        func text(workspace: URL?) -> String {
            HerNessPrompt.assemble(host.systemPromptSections(workspace: workspace, planMode: false))
        }

        XCTAssertTrue(text(workspace: workspace).contains("Durable memory"))
        XCTAssertTrue(text(workspace: workspace).contains(RememberTool.name))
        XCTAssertFalse(text(workspace: nil).contains("Durable memory"))
    }

    @MainActor
    func testBriefIsAskedOnlyWhereItCanBeRecorded() {
        let host = NativeAgentHost(paths: temporaryPaths(), endpoint: AgentEndpointController())
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())

        func text(workspace: URL?, planMode: Bool) -> String {
            HerNessPrompt.assemble(host.systemPromptSections(workspace: workspace, planMode: planMode))
        }

        XCTAssertTrue(text(workspace: workspace, planMode: false).contains("Project brief"))
        XCTAssertFalse(text(workspace: workspace, planMode: true).contains("Project brief"))
        XCTAssertFalse(text(workspace: nil, planMode: false).contains("Project brief"))
    }

    @MainActor
    func testPlanPromptListsExactlyTheToolsPlanModeOffers() {
        let host = NativeAgentHost(paths: temporaryPaths(), endpoint: AgentEndpointController())
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
        let offered = host.agentTools(workspace: workspace, planMode: true).defs.map(\.name)
        let prompt = HerNessPrompt.assemble(
            host.systemPromptSections(workspace: workspace, planMode: true))

        XCTAssertFalse(offered.contains("write_file"))
        XCTAssertFalse(offered.contains("remove_file"))
        XCTAssertTrue(offered.contains("run_command"))
        for name in offered {
            XCTAssertTrue(prompt.contains(name), "plan prompt does not mention \(name)")
        }
    }

    /// The four platform literals are generated from shared/prompts/*.txt. This
    /// runs the generator's own check, so a hand edit to any one of them fails here.
    func testEveryPlatformPromptLiteralMatchesTheCanonicalText() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/",
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("tools/sync_prompts.py").path) {
            root = root.deletingLastPathComponent()
        }
        let script = root.appendingPathComponent("tools/sync_prompts.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script.path), "checkout without tools/")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, text)
    }

    func testCoreStatesTrustPrecedence() {
        let core = HerNessPrompt.core(scope: "scope line", toolGuidance: "tool line")
        XCTAssertTrue(core.contains("scope line"))
        XCTAssertTrue(core.contains("tool line"))
        XCTAssertTrue(core.contains("tagged with a trust level"))
        XCTAssertFalse(core.contains("Clarification"))
    }

    @MainActor
    func testWorkspaceActivityListsOtherChatsRecentFilesOnly() throws {
        let paths = temporaryPaths()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let store = ConversationStore(paths: paths)
        var other = Conversation(id: "other", title: "Fix auth", cwd: workspace.path)
        other.messages = [
            ChatMessage(
                kind: .assistant,
                text: "done",
                changedFiles: [ChangedFile(path: "src/auth.swift", operation: .modified)]
            ),
            ChatMessage(
                kind: .assistant,
                text: "old work",
                createdAt: Date().addingTimeInterval(-3 * 3600),
                changedFiles: [ChangedFile(path: "src/stale.swift", operation: .modified)]
            ),
        ]
        store.save([other])

        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController())
        host.start(workspacePath: workspace.path)
        host.newConversation()
        let text = host.workspaceActivityText(workspace: workspace)
        XCTAssertTrue(text.contains("src/auth.swift"), text)
        XCTAssertTrue(text.contains("Fix auth"), text)
        XCTAssertFalse(text.contains("src/stale.swift"), text)
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTests-\(UUID().uuidString)", isDirectory: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
        paths.ensure()
        return paths
    }
}
