// Copyright (c) 2026 DOTS

import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

/// Real whisper inference on a fixture. Skipped unless a whisper model is installed and
/// `swift build --product WhisperVoice` has produced libWhisperVoice.dylib next to the test bundle.
final class LocalWhisperLiveTests: XCTestCase {
    func testInstalledWhisperTranscribesTheFixture() async throws {
        let paths = SupportPaths.default()
        let model = [LocalVoiceModel.whisperLargeV3Turbo, .whisperTinyQ5].first {
            FileManager.default.fileExists(atPath: paths.models.appendingPathComponent($0.filename).path)
        }
        guard let model else { throw XCTSkip("no whisper model in \(paths.models.path)") }

        let dylib = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("libWhisperVoice.dylib")
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw XCTSkip("build libWhisperVoice.dylib with: swift build --product WhisperVoice")
        }
        setenv("DOTS_WHISPER_LIBRARY", dylib.path, 1)

        let text = try await LocalVoiceTranscriber(paths: paths, model: model)
            .transcribe(samples: try VoiceFixture.samples(), sampleRate: 16_000)
        XCTAssertTrue(text.localizedCaseInsensitiveContains(VoiceFixture.phrase), "transcript was \(text.debugDescription)")
    }
}
