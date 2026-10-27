import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

final class MediaLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testGeneratedMediaIsFiledOnceUnderItsPrompt() throws {
        let paths = SupportPaths(
            root: root, plugins: root, presets: root, settings: root, hostPatch: root, trust: root,
            models: root, runtime: root
        )
        // "RIFF" is a wav container, whatever the kind's default extension says.
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0])
        let media = try MediaGenerationClient.save(wav, kind: .music, paths: paths, prompt: "lofi beat\nwith rain")
        _ = try MediaGenerationClient.save(wav, kind: .music, paths: paths, prompt: "again")

        XCTAssertEqual(media.url.pathExtension, "wav")
        let items = MediaLibrary.items(root: root)
        XCTAssertEqual(items.map(\.title), ["lofi beat"])
        XCTAssertEqual(items.first?.kind, .music)
        XCTAssertEqual(items.first?.path, media.path)
    }

    func testRemovingDeletesOnlyTheLibrarysOwnCopy() throws {
        let source = root.appendingPathComponent("Report.PDF")
        try Data("pdf".utf8).write(to: source)
        let generated = root.appendingPathComponent("clip.mp4")
        try Data("mp4".utf8).write(to: generated)

        let imported = try MediaLibrary.importFile(source, root: root)
        let recorded = MediaLibrary.record(generated, kind: .video, root: root)
        XCTAssertEqual(imported.kind, .document)
        XCTAssertEqual(imported.title, "Report.PDF")
        XCTAssertNotEqual(imported.path, source.path)
        XCTAssertEqual(MediaLibrary.items(root: root).map(\.id), [recorded.id, imported.id])

        MediaLibrary.remove(imported.id, root: root)
        MediaLibrary.remove(recorded.id, root: root)
        XCTAssertTrue(MediaLibrary.items(root: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.path))
    }

    func testMusicCommandAndOlderSettingsStillLoad() throws {
        XCTAssertEqual(MediaRequest.parse("/music calm piano"), MediaRequest(kind: .music, prompt: "calm piano"))
        let saved = Data(#"{"imageModel":"flux","videoSource":"local"}"#.utf8)
        let settings = try JSONDecoder().decode(MediaStudioSettings.self, from: saved)
        XCTAssertEqual(settings.imageModel, "flux")
        XCTAssertEqual(settings.videoSource, .local)
        XCTAssertEqual(settings.source(for: .music), .provider)
        XCTAssertNil(settings.musicEndpoint)

        var connected = MediaStudioSettings()
        connected.musicModel = "provider-model"
        let endpoint = MusicEndpoint(name: "Eleven", format: .elevenLabs)
        connected.musicEndpoints = [endpoint]
        XCTAssertEqual(connected.model(for: .music), "provider-model")
        connected.musicEndpointID = endpoint.id
        let reloaded = try JSONDecoder().decode(MediaStudioSettings.self, from: JSONEncoder().encode(connected))
        XCTAssertEqual(reloaded.musicEndpoint?.baseURL, "https://api.elevenlabs.io/v1")
        XCTAssertEqual(reloaded.model(for: .music), "music_v1")
    }
}
