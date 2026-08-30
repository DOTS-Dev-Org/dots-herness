import XCTest
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

final class VisionFallbackTests: XCTestCase {
    func testClassifiesOnlyExplicitImageCapabilityFailures() {
        XCTAssertTrue(VisionProviderCapability.isImageInputUnsupported(
            message: "model does not support image input", statusCode: 400))
        XCTAssertTrue(VisionProviderCapability.isImageInputUnsupported(
            message: "model does not support images", statusCode: 400))
        XCTAssertTrue(VisionProviderCapability.isImageInputUnsupported(
            message: "multimodal input is not supported", statusCode: 415))
        XCTAssertTrue(VisionProviderCapability.isImageInputUnsupported(
            message: "no image support on this endpoint", statusCode: 400))
        XCTAssertFalse(VisionProviderCapability.isImageInputUnsupported(
            message: "vision is not supported", statusCode: 401))
        XCTAssertFalse(VisionProviderCapability.isImageInputUnsupported(
            message: "invalid image payload", statusCode: 400))
        XCTAssertFalse(VisionProviderCapability.isImageInputUnsupported(
            message: "failed to decode image", statusCode: 400))
        XCTAssertFalse(VisionProviderCapability.isImageInputUnsupported(
            message: "vision is not supported", statusCode: 500))
        XCTAssertFalse(VisionProviderCapability.isImageInputUnsupported(
            message: "vision model was not found", statusCode: 400))
        XCTAssertFalse(VisionProviderCapability.isImageInputUnsupported(
            message: "vision model is not available", statusCode: 404))
        XCTAssertFalse(VisionProviderCapability.isImageInputUnsupported(
            message: "unknown model", statusCode: 404))
        XCTAssertFalse(VisionProviderCapability.isImageInputUnsupported(
            message: "model does not support text input", statusCode: 400))
    }

    @MainActor
    func testInstalledVisionPluginIsAddedToHostComposition() throws {
        let paths = temporaryPaths()
        let folder = paths.plugins.appendingPathComponent(VisionFallbackDefaults.pluginID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        id: dots.vision-fallback
        name: Vision fallback
        version: 1.0.0
        abi: 1.0.0
        plane: host
        """.write(to: folder.appendingPathComponent("plugin.yml"), atomically: true, encoding: .utf8)

        let catalog = PluginCatalog(paths: paths)
        catalog.refresh()
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)

        XCTAssertTrue(document.entries.contains { $0.plugin == VisionFallbackDefaults.pluginID })
    }

    @MainActor
    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessVisionTests-\(UUID().uuidString)", isDirectory: true)
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
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return paths
    }
}
