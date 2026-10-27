// Copyright (c) 2026 DOTS

import Foundation
import XCTest
@testable import DotsHarnessCore

final class VoiceStreamingSessionTests: XCTestCase {
    /// Holds the first batch call so later requests queue up behind it.
    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting.removeAll()
        }
    }

    private actor CallCounter {
        private(set) var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [VoiceTranscriptUpdate] = []

        func append(_ update: VoiceTranscriptUpdate) {
            lock.lock()
            values.append(update)
            lock.unlock()
        }

        var all: [VoiceTranscriptUpdate] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// 220 Hz tone at speech level, or digital silence, at 16 kHz.
    private static func tone(seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
    }

    private static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    /// A finished utterance must still produce its final transcript when a newer
    /// utterance starts while the earlier batch request is still running.
    func testFinalTranscriptSurvivesOverlappingInference() async {
        let gate = Gate()
        let calls = CallCounter()
        let updates = Updates()
        let session = VoiceStreamingSession(
            mode: .rollingWhisper,
            batchTranscriber: { _ in
                let call = await calls.next()
                if call == 1 { await gate.wait() }
                return "text \(call)"
            },
            onUpdate: { updates.append($0) },
            onError: { _ in }
        )

        session.push(Self.tone(seconds: 2))      // partial #1 starts and blocks
        for _ in 0..<100 {
            if await calls.count >= 1 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        session.push(Self.silence(seconds: 1))   // utterance #1 ends: its final must wait
        session.push(Self.tone(seconds: 2))      // utterance #2 starts: must not drop that final
        await gate.open()

        await withCheckedContinuation { done in
            session.stop { done.resume() }
        }

        let finals = updates.all.filter(\.isFinal)
        XCTAssertEqual(finals.count, 2, "each utterance needs a final transcript, got \(updates.all)")
    }
}
