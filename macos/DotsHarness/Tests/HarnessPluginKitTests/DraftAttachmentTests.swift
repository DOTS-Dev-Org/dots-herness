import XCTest
import Foundation
import PluginRuntime
@testable import DotsHarnessCore

final class DraftAttachmentTests: XCTestCase {
    @MainActor
    func testRemovingMiddleDraftAttachmentMatchesStableID() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = AppModel(paths: paths)
        for byte in 1...3 {
            model.addDraftImageData(Data([UInt8(byte)]))
        }

        let before = model.draftAttachments
        var changed = before[1]
        changed.sourceStatus = .changed
        model.draftAttachments[1] = changed
        model.removeDraftAttachment(before[1])

        XCTAssertEqual(model.draftAttachments.map { $0.id }, [before[0].id, before[2].id])
    }

    @MainActor
    func testRepeatedImagePastesCreateDistinctDraftAttachments() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = AppModel(paths: paths)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])

        model.addDraftImageData(imageData)
        model.addDraftImageData(imageData)

        XCTAssertEqual(model.draftAttachments.count, 2)
        XCTAssertNotEqual(model.draftAttachments[0].id, model.draftAttachments[1].id)
        XCTAssertNotEqual(model.draftAttachments[0].path, model.draftAttachments[1].path)
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
