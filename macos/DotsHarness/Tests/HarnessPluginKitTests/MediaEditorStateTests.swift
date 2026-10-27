import AppKit
import XCTest
@testable import DotsHarnessCore
@testable import DotsHarnessUI

@MainActor
final class MediaEditorStateTests: XCTestCase {
    private func makeState() -> (MediaEditorState, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-state-\(UUID().uuidString)")
        let store = MediaStudioStore(root: root)
        store.loadIfNeeded()
        let state = MediaEditorState(project: store.create(name: "Board"), store: store)
        state.zoom = 1
        return (state, root)
    }

    func testLayersAndCanvasesMoveIntoTheCanvasTheyAreDroppedOn() throws {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }

        state.place(.frame, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1000, y: 800))
        let outer = try XCTUnwrap(state.canvas)
        // Drawn inside the first canvas, the second becomes its child.
        state.place(.frame, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 400))
        let inner = try XCTUnwrap(state.canvas)
        XCTAssertEqual(inner.parentID, outer.id)
        XCTAssertEqual(state.descendants(of: outer.id).map(\.id), [inner.id])

        // A shape drawn over the inner canvas lands in it, in its coordinates.
        state.place(.rectangle, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 250))
        let layer = try XCTUnwrap(state.layer)
        XCTAssertEqual(state.canvasID, inner.id)
        XCTAssertEqual(layer.x, 50)

        // Dragged out over the outer canvas, it changes owner and keeps its place on the board.
        state.updateLayer(layer.id, in: inner.id) { $0.x = 500 }
        state.rehomeLayer(layer.id, from: inner.id)
        XCTAssertEqual(state.canvasID, outer.id)
        XCTAssertEqual(state.layer?.x, 600)
        XCTAssertTrue(state.project.canvases.first { $0.id == inner.id }?.layers.isEmpty == true)

        // Moved clear of its parent, the inner canvas stands alone again.
        state.updateCanvas(inner.id) { $0.x = 2000 }
        state.reparentCanvas(inner.id)
        XCTAssertNil(state.project.canvases.first { $0.id == inner.id }?.parentID)
    }

    func testCopyPasteCutDeleteAndBoundedUndo() throws {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = NSPasteboard.general.pasteboardItems?.compactMap { $0.string(forType: .string) }.first
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        state.place(.frame, from: .zero, to: CGPoint(x: 600, y: 600))
        state.place(.frame, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 200))
        let outerID = try XCTUnwrap(state.project.canvases.first?.id)
        state.select(canvas: outerID)
        state.place(.ellipse, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 400, y: 400))

        state.copySelection()
        state.paste()
        XCTAssertEqual(state.canvas?.layers.count, 2)
        XCTAssertNotEqual(state.canvas?.layers[0].id, state.canvas?.layers[1].id)
        XCTAssertEqual(state.canvas?.layers[1].x, 324)

        state.cutSelection()
        XCTAssertEqual(state.canvas?.layers.count, 1)
        state.undo()
        XCTAssertEqual(state.canvas?.layers.count, 2)

        // Copying a canvas takes the canvases nested in it; the copies point at each other, not the originals.
        state.select(canvas: outerID)
        state.copySelection()
        state.paste()
        XCTAssertEqual(state.project.canvases.count, 4)
        let copies = state.project.canvases.suffix(2)
        XCTAssertEqual(copies.last?.parentID, copies.first?.id)

        // Deleting a canvas deletes what is nested in it, and undo brings both back.
        state.deleteSelection()
        XCTAssertEqual(state.project.canvases.count, 2)
        state.undo()
        XCTAssertEqual(state.project.canvases.count, 4)

        for _ in 0..<40 { state.nudge(dx: 0, dy: 0); state.checkpoint() }
        var steps = 0
        while state.canUndo { state.undo(); steps += 1 }
        XCTAssertEqual(steps, MediaEditorState.historyLimit)
    }
}
