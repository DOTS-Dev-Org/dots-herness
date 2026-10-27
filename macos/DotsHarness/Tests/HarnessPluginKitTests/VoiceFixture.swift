// Copyright (c) 2026 DOTS

import AVFoundation
import Foundation
import XCTest

/// Speech shared by the live voice tests: "This is a voice input test for the dictation feature.", 16 kHz mono.
enum VoiceFixture {
    static let phrase = "voice input test"

    static func samples() throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/voice-input-en-16k.wav")
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
    }
}
