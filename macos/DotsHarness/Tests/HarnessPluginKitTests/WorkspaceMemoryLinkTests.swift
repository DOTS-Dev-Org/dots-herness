import XCTest
@testable import DotsHarnessCore
import PluginRuntime

/// The repository's `.mem` is untrusted input. A link anywhere under it must not make the
/// migration read, copy or delete files that live outside the repository.
@MainActor
final class WorkspaceMemoryLinkTests: XCTestCase {
    private let fileManager = FileManager.default

    func testLinkedFoldersInsideMemNeverReachOutsideFiles() throws {
        let sandbox = try makeSandbox()
        defer { try? fileManager.removeItem(at: sandbox.base) }
        let memory = makeMemory(workspace: sandbox.repo)
        let mem = sandbox.repo.appendingPathComponent(".mem", isDirectory: true)

        for folder in ["tasks", "conversations", "events"] {
            let entry = mem.appendingPathComponent(folder, isDirectory: true)
            try? fileManager.removeItem(at: entry)
            try fileManager.createSymbolicLink(at: entry, withDestinationURL: sandbox.outside)
        }

        memory.reload()

        XCTAssertEqual(try String(contentsOf: sandbox.outside.appendingPathComponent("secret.txt"), encoding: .utf8), "secret")
        XCTAssertTrue(fileManager.fileExists(atPath: sandbox.outside.appendingPathComponent("keep.json").path))
        let userRoot = try XCTUnwrap(memory.userMemoryDirectory)
        XCTAssertFalse(fileManager.fileExists(atPath: userRoot.appendingPathComponent("tasks/secret.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: userRoot.appendingPathComponent("conversations/secret.txt").path))
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: mem.appendingPathComponent("events").path))
    }

    func testLinkedMemRootIsLeftAlone() throws {
        let sandbox = try makeSandbox()
        defer { try? fileManager.removeItem(at: sandbox.base) }
        let memory = makeMemory(workspace: sandbox.repo)
        try memory.setProjectDefault(key: "goal", value: "keep")
        let mem = sandbox.repo.appendingPathComponent(".mem", isDirectory: true)
        let other = sandbox.outside.appendingPathComponent("other-mem", isDirectory: true)
        try fileManager.moveItem(at: mem, to: other)
        try fileManager.createSymbolicLink(at: mem, withDestinationURL: other)
        try "facts".write(to: other.appendingPathComponent("facts.md"), atomically: true, encoding: .utf8)
        let events = other.appendingPathComponent("events", isDirectory: true)
        let eventCount = try fileManager.contentsOfDirectory(atPath: events.path).count
        XCTAssertGreaterThan(eventCount, 0)

        memory.reload()

        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("facts.md"), encoding: .utf8), "facts")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: events.path).count, eventCount)
    }

    func testLinkInsideARealFolderIsNotCopiedIntoTheUserLayer() throws {
        let sandbox = try makeSandbox()
        defer { try? fileManager.removeItem(at: sandbox.base) }
        let memory = makeMemory(workspace: sandbox.repo)
        let folder = sandbox.repo.appendingPathComponent(".mem/tasks/nested", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("link.md")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: sandbox.outside.appendingPathComponent("secret.txt"))

        memory.reload()

        let copied = try XCTUnwrap(memory.userMemoryDirectory).appendingPathComponent("tasks/nested/link.md").path
        let type = (try? fileManager.attributesOfItem(atPath: copied))?[.type] as? FileAttributeType
        XCTAssertNotEqual(type, .typeSymbolicLink)
        if type == .typeRegular {
            XCTAssertNotEqual(try? String(contentsOfFile: copied, encoding: .utf8), "secret")
        }
    }

    private struct Sandbox {
        let base: URL
        let repo: URL
        let outside: URL
    }

    private func makeSandbox() throws -> Sandbox {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("WorkspaceMemoryLinkTests-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: repo, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: outside.appendingPathComponent("keep.json"), atomically: true, encoding: .utf8)
        return Sandbox(base: base, repo: repo, outside: outside)
    }

    private func makeMemory(workspace: URL) -> WorkspaceMemory {
        let memory = WorkspaceMemory(paths: temporaryPaths())
        memory.setWorkspace(workspace)
        memory.prepareForPrompt(prompt: "start", runID: UUID(), provider: "test", model: "test")
        return memory
    }

    private func temporaryPaths() -> SupportPaths {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("WorkspaceMemoryLinkTests-paths-\(UUID().uuidString)", isDirectory: true)
        return SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
    }
}
