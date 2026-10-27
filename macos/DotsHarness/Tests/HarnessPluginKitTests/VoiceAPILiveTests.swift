// Copyright (c) 2026 DOTS

import Foundation
import XCTest
@testable import DotsHarnessCore

/// Live check of the API voice provider on the speech fixture. Opt-in like LiveProviderTests;
/// the key comes from the environment, so no credential is written into the repo.
///
///   DOTS_LIVE=1 DOTS_TEST_GROQ_KEY=gsk_… swift test --filter VoiceAPILiveTests
///
/// Any OpenAI-compatible server works when DOTS_TEST_VOICE_API_URL is set; it needs no key:
///   DOTS_LIVE=1 DOTS_TEST_VOICE_API_URL=http://127.0.0.1:18799/v1 swift test --filter VoiceAPILiveTests
final class VoiceAPILiveTests: XCTestCase {
    private static let groqEndpoint = "https://api.groq.com/openai/v1"

    private func configuration() throws -> VoiceAPIConfiguration {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["DOTS_LIVE"] == "1", "Set DOTS_LIVE=1 to call a live voice API.")
        let endpoint = environment["DOTS_TEST_VOICE_API_URL"] ?? Self.groqEndpoint
        let key = environment["DOTS_TEST_GROQ_KEY"] ?? ""
        try XCTSkipIf(endpoint == Self.groqEndpoint && key.isEmpty, "Set DOTS_TEST_GROQ_KEY to test Groq.")
        return VoiceAPIConfiguration(endpoint: endpoint, apiKey: key, model: "whisper-large-v3-turbo")
    }

    /// One utterance, one request: what the API provider sends for a finished utterance.
    func testEndpointTranscribesTheFixture() async throws {
        let configuration = try configuration()
        let text = try await VoiceAPITranscriber.transcribe(
            samples: try VoiceFixture.samples(), sampleRate: 16_000, configuration: configuration)
        XCTAssertTrue(text.localizedCaseInsensitiveContains(VoiceFixture.phrase), "transcript was \(text.debugDescription)")
    }

    /// The app's path without a realtime endpoint: VAD cuts the utterance, then one HTTP request
    /// per utterance yields the final transcript.
    func testUtteranceModeEmitsAFinalTranscript() async throws {
        let configuration = try configuration()
        let updates = LockedList<VoiceTranscriptUpdate>()
        let errors = LockedList<String>()
        let session = VoiceStreamingSession(
            mode: .utteranceHTTP,
            batchTranscriber: { samples in
                try await VoiceAPITranscriber.transcribe(samples: samples, sampleRate: 16_000, configuration: configuration)
            },
            onUpdate: { updates.append($0) },
            onError: { errors.append($0.localizedDescription) }
        )

        let samples = try VoiceFixture.samples()
        for start in stride(from: 0, to: samples.count, by: 2_560) {   // 160 ms chunks, as the mic tap delivers them
            session.push(Array(samples[start..<min(start + 2_560, samples.count)]))
        }
        await withCheckedContinuation { done in
            session.stop { done.resume() }
        }

        let finals = updates.all.filter(\.isFinal).map(\.text)
        XCTAssertTrue(finals.contains { $0.localizedCaseInsensitiveContains(VoiceFixture.phrase) },
                      "finals \(finals), errors \(errors.all)")
    }
}

/// Values produced on the session's callback threads.
private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
