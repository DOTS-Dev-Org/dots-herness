import XCTest
import Foundation
import UniformTypeIdentifiers
import PluginRuntime
@testable import DotsHarnessCore

final class DraftAttachmentTests: XCTestCase {
    @MainActor
    func testRemovingMiddleDraftAttachmentMatchesStableID() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = AppModel(paths: paths)
        for byte in 1...3 {
            model.addDraftImageData(Data([UInt8(byte)]))
        }
        try await waitForDraftAttachmentCount(3, in: model)

        let before = model.draftAttachments
        var changed = before[1]
        changed.sourceStatus = .changed
        model.draftAttachments[1] = changed
        model.removeDraftAttachment(before[1])

        XCTAssertEqual(model.draftAttachments.map { $0.id }, [before[0].id, before[2].id])
    }

    @MainActor
    func testRepeatedImagePastesCreateDistinctDraftAttachments() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = AppModel(paths: paths)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])

        model.addDraftImageData(imageData)
        model.addDraftImageData(imageData)
        try await waitForDraftAttachmentCount(2, in: model)

        XCTAssertEqual(model.draftAttachments.count, 2)
        XCTAssertNotEqual(model.draftAttachments[0].id, model.draftAttachments[1].id)
        XCTAssertNotEqual(model.draftAttachments[0].path, model.draftAttachments[1].path)
    }

    @MainActor
    func testMixedDraftAttachmentBatchPreservesFileAndImageOrder() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fileURL = paths.root.appendingPathComponent("first.txt")
        try Data("file".utf8).write(to: fileURL)
        let model = AppModel(paths: paths)

        model.addDraftAttachmentInputs([
            .file(fileURL),
            .imageData(Data([0x89, 0x50, 0x4E, 0x47]), typeIdentifier: UTType.png.identifier),
        ])
        try await waitForDraftAttachmentCount(2, in: model)

        XCTAssertEqual(model.draftAttachments.map { $0.kind.rawValue }, ["file", "image"])
        XCTAssertEqual(model.draftAttachments[0].url, fileURL)
        XCTAssertEqual(model.draftAttachments[1].url.pathExtension, "png")
    }

    @MainActor
    private func waitForDraftAttachmentCount(_ count: Int, in model: AppModel) async throws {
        for _ in 0..<200 {
            if model.draftAttachments.count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(count) draft attachments")
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
