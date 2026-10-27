import Foundation
import XCTest
@testable import DotsHarnessCore

final class MediaStudioTests: XCTestCase {
    func testPlanParsingKeepsValidLayersInsideTheCanvas() throws {
        let reply = """
        Here is the design:
        ```json
        {"background":"#0a1b2c","layers":[
          {"type":"shape","name":"Band","x":-40,"y":900,"width":5000,"height":180,"color":"#ffaa00"},
          {"type":"text","name":"Title","x":80,"y":100,"width":900,"height":200,"text":"Merhaba","fontSize":96,"align":"leading"},
          {"type":"image","name":"Hero","x":100,"y":300,"width":400,"height":400,"prompt":"a red kite"},
          {"type":"text","name":"Empty","x":0,"y":0,"width":100,"height":50,"text":""},
          {"type":"video","x":0,"y":0,"width":100,"height":100},
          {"type":"shape","x":0,"y":0,"width":0,"height":10}
        ]}
        ```
        """
        let canvas = MediaCanvas(name: "Post", width: 1080, height: 1080)
        let plan = try XCTUnwrap(MediaStudioAI.parsePlan(reply, canvas: canvas))

        XCTAssertEqual(plan.backgroundHex, "#0A1B2C")
        XCTAssertEqual(plan.steps.map(\.layer.name), ["Band", "Title", "Hero"])
        let band = plan.steps[0].layer
        XCTAssertEqual(band.width, 1080)
        XCTAssertEqual(band.x, 0)
        XCTAssertEqual(band.colorHex, "#FFAA00")
        XCTAssertEqual(plan.steps[1].layer.alignment, .leading)
        XCTAssertNil(plan.steps[1].imagePrompt)
        XCTAssertEqual(plan.steps[2].imagePrompt, "a red kite")

        XCTAssertNil(MediaStudioAI.parsePlan("Sorry, I cannot do that.", canvas: canvas))
    }

    func testPlanEditsExistingLayersByShortID() throws {
        var canvas = MediaCanvas(name: "Home", width: 400, height: 300)
        canvas.layers = [
            MediaLayer(name: "Card", kind: .shape, x: 10, y: 10, width: 100, height: 100, colorHex: "#FFFFFF"),
            MediaLayer(name: "Title", kind: .text, x: 20, y: 20, width: 200, height: 40, text: "Hi", fontSize: 20),
            MediaLayer(name: "Old", kind: .shape, x: 0, y: 0, width: 10, height: 10),
        ]
        let reply = """
        {"name":"Home v2","remove":["L3","L9"],
         "update":[{"id":"L2","fontSize":32,"color":"#ff0000"},{"id":"L3","x":5},{"id":"nope","x":1}],
         "layers":[{"type":"icon","name":"Paw","x":300,"y":10,"width":40,"height":40,"symbol":"pawprint.fill","color2":"#00ff00","shadow":8}]}
        """
        let plan = try XCTUnwrap(MediaStudioAI.parsePlan(reply, canvas: canvas))

        XCTAssertEqual(plan.name, "Home v2")
        XCTAssertEqual(plan.removals, [canvas.layers[2].id])
        XCTAssertEqual(plan.updates.map(\.id), [canvas.layers[1].id])
        XCTAssertEqual(plan.updates[0].fontSize, 32)
        XCTAssertEqual(plan.updates[0].colorHex, "#FF0000")
        XCTAssertEqual(plan.updates[0].text, "Hi")
        XCTAssertEqual(plan.steps[0].layer.symbol, "pawprint.fill")
        XCTAssertEqual(plan.steps[0].layer.gradientHex, "#00FF00")
        XCTAssertEqual(plan.steps[0].layer.shadow, 8)

        let request = MediaStudioAI.planMessages(prompt: "bigger", canvas: canvas, selectedLayerID: canvas.layers[1].id, imagesAvailable: false)
        XCTAssertTrue(request[1].content.contains("\"id\":\"L2\""))
        XCTAssertTrue(request[1].content.contains("Selected layer"))
        XCTAssertTrue(request[0].content.contains("do not add image layers"))
    }

    func testLayersSavedBeforeNewFieldsStillDecode() throws {
        let old = ##"{"id":"a","name":"Box","kind":"shape","x":1,"y":2,"width":3,"height":4,"opacity":1,"hidden":false,"text":"","fontSize":48,"fontWeight":"bold","alignment":"center","colorHex":"#111111","shape":"rectangle","cornerRadius":0}"##
        let layer = try JSONDecoder().decode(MediaLayer.self, from: Data(old.utf8))
        XCTAssertEqual(layer.rotation, 0)
        XCTAssertFalse(layer.locked)
        XCTAssertNil(layer.gradientHex)
    }

    @MainActor
    func testProjectsAndAssetsSurviveAReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaStudioStore(root: root)
        store.loadIfNeeded()
        var project = store.create(name: "Poster", canvas: MediaCanvas(name: "Poster", width: 1080, height: 1080))

        let source = root.appendingPathComponent("source.png")
        try Data([1, 2, 3]).write(to: source)
        let asset = try store.importAsset(from: source, into: project.id)
        project.canvases[0].layers.append(
            MediaLayer(name: "Photo", kind: .image, x: 0, y: 0, width: 10, height: 10, assetName: asset)
        )
        store.save(project)
        store.settings.imageSource = .local

        let reloaded = MediaStudioStore(root: root)
        reloaded.loadIfNeeded()
        XCTAssertEqual(reloaded.projects.map(\.name), ["Poster"])
        XCTAssertEqual(reloaded.projects[0].canvases[0].layers.last?.assetName, asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.assetURL(projectID: project.id, name: asset).path))
        XCTAssertEqual(reloaded.settings.imageSource, .local)

        reloaded.delete(project.id)
        XCTAssertTrue(reloaded.projects.isEmpty)
    }
}

final class MediaCommunityTests: XCTestCase {
    @MainActor
    func testFeedDropsUnreadablePostsAndLocalFiles() throws {
        var canvas = MediaCanvas(name: "Post", width: 1080, height: 1080)
        var image = MediaLayer(name: "Hero", kind: .image, x: 0, y: 0, width: 100, height: 100)
        image.assetName = "../../secret.png"
        var note = MediaLayer(name: "Note", kind: .text, x: 0, y: 0, width: 100, height: 40, text: "todo")
        note.comment = true
        canvas.layers = [image, note]
        let good = MediaCommunityPost(id: "a", title: "Good", author: "ali", category: "social", likes: 3, canvas: canvas)
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let feed = #"{"version":1,"posts":[\#(goodJSON),{"id":"b","title":"Broken"}]}"#

        let posts = MediaCommunityClient.decodeFeed(Data(feed.utf8))

        XCTAssertEqual(posts.map(\.id), ["a"])
        XCTAssertEqual(posts[0].canvas.layers.map(\.name), ["Hero"])
        XCTAssertNil(posts[0].canvas.layers[0].assetName)
        XCTAssertNotEqual(posts[0].canvas.id, canvas.id)
    }
}
