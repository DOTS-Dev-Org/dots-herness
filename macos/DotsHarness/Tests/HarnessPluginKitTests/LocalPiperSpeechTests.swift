// Copyright (c) 2026 DOTS
// Piper TTS runtime pins, offline fallback, and the runtime-loaded synthesis path.

import XCTest
import PluginRuntime
import DotsHarnessCore

final class LocalPiperSpeechTests: XCTestCase {
    func testRuntimePinsAreWellFormed() {
        for archive in [LocalSpeechRuntime.piper.sherpa, LocalSpeechRuntime.piper.onnxruntime] {
            XCTAssertEqual(archive.sha256.count, 64)
            XCTAssertTrue(archive.sha256.allSatisfy(\.isHexDigit))
            XCTAssertGreaterThan(archive.bytes, 0)
            XCTAssertEqual(archive.url.scheme, "https")
        }
        for binary in [LocalSpeechRuntime.piper.sherpaBinarySHA256, LocalSpeechRuntime.piper.onnxruntimeBinarySHA256] {
            XCTAssertEqual(binary.count, 64)
            XCTAssertTrue(binary.allSatisfy(\.isHexDigit))
        }
    }

    /// Model files without the runtime: Turkish speech must fail fast (the caller then
    /// uses the system voice) and must not touch the network.
    func testSynthesisFailsFastWhenRuntimeIsMissing() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeFakeModelFiles(into: paths)

        let synthesizer = LocalPiperSpeechSynthesizer(paths: paths, autoInstallRuntime: false)
        XCTAssertTrue(synthesizer.isModelInstalled)
        XCTAssertFalse(synthesizer.isRuntimeInstalled)

        do {
            _ = try await synthesizer.synthesize("Merhaba")
            XCTFail("expected synthesis to fail without the runtime")
        } catch {
            XCTAssertFalse(synthesizer.isRuntimeInstalled)
        }
    }

    /// Opt-in: downloads about 75 MB from GitHub. Covers explicit install, then a deleted
    /// runtime that synthesis must fetch again in the background.
    /// Run: DOTS_PIPER_E2E=1 swift test --filter LocalPiperSpeechTests
    func testSynthesizesTurkishSpeechThroughRuntime() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOTS_PIPER_E2E"] == "1", "network test; set DOTS_PIPER_E2E=1")

        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let synthesizer = LocalPiperSpeechSynthesizer(paths: paths)
        XCTAssertFalse(synthesizer.isModelInstalled)

        try await synthesizer.ensureModel()
        XCTAssertTrue(synthesizer.isModelInstalled)
        XCTAssertTrue(synthesizer.isRuntimeInstalled)
        try await assertSpeechIsProduced(by: synthesizer)

        // Simulate an upgraded user whose runtime is gone: the first request falls back,
        // the runtime arrives in the background, and the next request uses Piper again.
        try FileManager.default.removeItem(at: paths.runtime.appendingPathComponent(LocalSpeechRuntime.piper.id, isDirectory: true))
        XCTAssertFalse(synthesizer.isRuntimeInstalled)
        do {
            _ = try await synthesizer.synthesize("Merhaba")
            XCTFail("expected fallback while the runtime is missing")
        } catch {}

        let deadline = Date().addingTimeInterval(240)
        while !synthesizer.isRuntimeInstalled, Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(synthesizer.isRuntimeInstalled, "background install did not finish")
        try await assertSpeechIsProduced(by: synthesizer)
    }

    private func makePaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("piper-test-\(UUID().uuidString)", isDirectory: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins"),
            presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings"),
            hostPatch: root.appendingPathComponent("host-patch"),
            trust: root.appendingPathComponent("trust"),
            models: root.appendingPathComponent("models"),
            runtime: root.appendingPathComponent("runtime")
        )
        paths.ensure()
        return paths
    }

    private func writeFakeModelFiles(into paths: SupportPaths) throws {
        let fm = FileManager.default
        let modelRoot = paths.models
            .appendingPathComponent("speech", isDirectory: true)
            .appendingPathComponent(LocalSpeechModel.turkishPiper.id, isDirectory: true)
        try fm.createDirectory(at: modelRoot.appendingPathComponent("espeak-ng-data", isDirectory: true), withIntermediateDirectories: true)
        try Data().write(to: modelRoot.appendingPathComponent(LocalSpeechModel.turkishPiper.modelFilename))
        try Data().write(to: modelRoot.appendingPathComponent("tokens.txt"))
    }

    private func assertSpeechIsProduced(by synthesizer: LocalPiperSpeechSynthesizer) async throws {
        let wav = try await synthesizer.synthesize("Merhaba, bu bir Piper test cümlesidir.")
        let data = try Data(contentsOf: wav)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertGreaterThan(data.count, 44 + 2 * 22_050, "expected more than one second of 22.05 kHz audio")
    }
}
