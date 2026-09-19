// Copyright (c) 2026 DOTS
// Small streaming primitives shared by local and API voice input.

import Foundation

public struct VoiceTranscriptUpdate: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public struct VoiceStreamTuning: Sendable, Equatable {
    public var sampleRate = 16_000
    public var frameSamples = 320 // 20 ms
    public var chunkSamples = 2_560 // 160 ms
    public var rollingWindowSamples = 48_000 // 3 s
    public var inferenceStepSamples = 5_120 // 320 ms
    public var preRollSamples = 3_200 // 200 ms
    public var onsetFrames = 10 // 200 ms
    public var minimumSpeechFrames = 12 // 240 ms
    public var endpointSilenceFrames = 40 // 800 ms

    public init() {}
}

public enum VoiceActivityEvent: Sendable {
    case speechStarted([Float])
    case audio([Float])
    case utteranceEnded
}

/// Energy VAD with hysteresis and hangover. It intentionally does not try to
/// identify words; the recognizer remains responsible for the transcript.
public final class VoiceActivityDetector: @unchecked Sendable {
    private let tuning: VoiceStreamTuning
    private var pendingSamples: [Float] = []
    private var preRoll: [Float] = []
    private var candidate: [Float] = []
    private var isSpeaking = false
    private var aboveOnsetFrames = 0
    private var silentFrames = 0
    private var noiseFloor: Float = 0.008

    public init(tuning: VoiceStreamTuning = VoiceStreamTuning()) {
        self.tuning = tuning
    }

    public func consume(_ samples: [Float]) -> [VoiceActivityEvent] {
        guard !samples.isEmpty else { return [] }
        pendingSamples.append(contentsOf: samples)
        var events: [VoiceActivityEvent] = []

        while pendingSamples.count >= tuning.frameSamples {
            let frame = Array(pendingSamples.prefix(tuning.frameSamples))
            pendingSamples.removeFirst(tuning.frameSamples)
            process(frame, events: &events)
        }
        return events
    }

    public func flush() -> [VoiceActivityEvent] {
        var events: [VoiceActivityEvent] = []
        if !pendingSamples.isEmpty {
            let frame = pendingSamples
            pendingSamples.removeAll(keepingCapacity: true)
            process(frame, events: &events)
        }
        if isSpeaking {
            events.append(.utteranceEnded)
        }
        reset()
        return events
    }

    public func reset() {
        pendingSamples.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        candidate.removeAll(keepingCapacity: true)
        isSpeaking = false
        aboveOnsetFrames = 0
        silentFrames = 0
    }

    private func process(_ frame: [Float], events: inout [VoiceActivityEvent]) {
        let level = rms(frame)
        let startThreshold = max(0.018, noiseFloor * 3.0)
        let stopThreshold = max(0.012, noiseFloor * 1.8)

        if isSpeaking {
            events.append(.audio(frame))
            if level < stopThreshold {
                silentFrames += 1
                if silentFrames >= tuning.endpointSilenceFrames {
                    events.append(.utteranceEnded)
                    reset()
                }
            } else {
                silentFrames = 0
            }
            return
        }

        if level >= startThreshold {
            candidate.append(contentsOf: frame)
            aboveOnsetFrames += 1
            if aboveOnsetFrames >= tuning.onsetFrames,
               candidate.count >= tuning.minimumSpeechFrames * tuning.frameSamples {
                isSpeaking = true
                silentFrames = 0
                let start = preRoll + candidate
                preRoll.removeAll(keepingCapacity: true)
                candidate.removeAll(keepingCapacity: true)
                events.append(.speechStarted(start))
            }
        } else {
            noiseFloor = min(0.2, noiseFloor * 0.95 + level * 0.05)
            if !candidate.isEmpty {
                preRoll.append(contentsOf: candidate)
                candidate.removeAll(keepingCapacity: true)
            }
            preRoll.append(contentsOf: frame)
            if preRoll.count > tuning.preRollSamples {
                preRoll.removeFirst(preRoll.count - tuning.preRollSamples)
            }
            aboveOnsetFrames = 0
        }
    }

    private func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(Float.zero) { $0 + $1 * $1 }
        return sqrt(sum / Float(frame.count))
    }
}

public enum VoiceStreamingMode: Sendable, Equatable {
    case rollingWhisper
    case utteranceHTTP
    case realtime
}

/// Serializes VAD and inference scheduling while keeping audio callbacks cheap.
/// Batch backends receive only the current utterance/rolling window, never the
/// complete microphone session.
public final class VoiceStreamingSession: @unchecked Sendable {
    public typealias BatchTranscriber = @Sendable ([Float]) async throws -> String
    public typealias RealtimePusher = @Sendable ([Float]) -> Void
    public typealias RealtimeAction = @Sendable () -> Void
    public typealias UpdateHandler = @Sendable (VoiceTranscriptUpdate) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void

    private let mode: VoiceStreamingMode
    private let batchTranscriber: BatchTranscriber?
    private let realtimePush: RealtimePusher?
    private let realtimeCommit: RealtimeAction?
    private let realtimeCancel: RealtimeAction?
    private let onUpdate: UpdateHandler
    private let onError: ErrorHandler
    private let tuning: VoiceStreamTuning
    private let queue = DispatchQueue(label: "com.dots.dotsharness.voice-stream", qos: .userInitiated)

    private var detector: VoiceActivityDetector
    private var utterance: [Float] = []
    private var rolling: [Float] = []
    private var samplesSinceInference = 0
    private var inferenceRunning = false
    private var pendingInference: (samples: [Float], isFinal: Bool)?
    private var stopRequested = false
    private var stopHandler: (@Sendable () -> Void)?
    private var cancelled = false

    public init(
        mode: VoiceStreamingMode,
        tuning: VoiceStreamTuning = VoiceStreamTuning(),
        batchTranscriber: BatchTranscriber? = nil,
        realtimePush: RealtimePusher? = nil,
        realtimeCommit: RealtimeAction? = nil,
        realtimeCancel: RealtimeAction? = nil,
        onUpdate: @escaping UpdateHandler,
        onError: @escaping ErrorHandler
    ) {
        self.mode = mode
        self.tuning = tuning
        self.batchTranscriber = batchTranscriber
        self.realtimePush = realtimePush
        self.realtimeCommit = realtimeCommit
        self.realtimeCancel = realtimeCancel
        self.onUpdate = onUpdate
        self.onError = onError
        self.detector = VoiceActivityDetector(tuning: tuning)
    }

    public func push(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.cancelled, !self.stopRequested else { return }
            for event in self.detector.consume(samples) {
                self.consume(event)
            }
        }
    }

    public func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, !self.cancelled, !self.stopRequested else { return }
            self.stopRequested = true
            self.stopHandler = completion
            for event in self.detector.flush() {
                self.consume(event)
            }
            self.finishIfPossible()
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.cancelled = true
            self.detector.reset()
            self.utterance.removeAll(keepingCapacity: true)
            self.rolling.removeAll(keepingCapacity: true)
            self.pendingInference = nil
            self.realtimeCancel?()
            self.stopHandler = nil
        }
    }

    private func consume(_ event: VoiceActivityEvent) {
        switch event {
        case let .speechStarted(samples):
            append(samples)
            if mode == .realtime {
                realtimePush?(samples)
            }
        case let .audio(samples):
            append(samples)
            if mode == .realtime {
                realtimePush?(samples)
            } else if mode == .rollingWhisper {
                samplesSinceInference += samples.count
                guard samplesSinceInference >= tuning.inferenceStepSamples,
                      utterance.count >= tuning.sampleRate else { return }
                samplesSinceInference = 0
                scheduleBatch(rolling, isFinal: false)
            }
        case .utteranceEnded:
            if mode == .realtime {
                realtimeCommit?()
            } else {
                scheduleBatch(utterance, isFinal: true)
            }
            utterance.removeAll(keepingCapacity: true)
            rolling.removeAll(keepingCapacity: true)
            samplesSinceInference = 0
        }
    }

    private func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        utterance.append(contentsOf: samples)
        if utterance.count > tuning.sampleRate * 30 {
            // ponytail: cap one utterance at 30 s; split at the next endpoint instead of retaining an unbounded recording.
            utterance.removeFirst(utterance.count - tuning.sampleRate * 30)
        }
        rolling.append(contentsOf: samples)
        if rolling.count > tuning.rollingWindowSamples {
            rolling.removeFirst(rolling.count - tuning.rollingWindowSamples)
        }
    }

    private func scheduleBatch(_ samples: [Float], isFinal: Bool) {
        guard let batchTranscriber,
              samples.count >= 1_600 else { return }
        let request = (samples, isFinal)
        if inferenceRunning {
            pendingInference = request
            return
        }
        inferenceRunning = true
        let update = onUpdate
        let reportError = onError
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let text = try await batchTranscriber(request.0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    update(VoiceTranscriptUpdate(text: text, isFinal: request.1))
                }
            } catch is CancellationError {
                // Session cancellation is expected when the view disappears.
            } catch {
                if request.1 { reportError(error) }
            }
            guard let self else { return }
            self.queue.async {
                self.inferenceRunning = false
                if let pending = self.pendingInference {
                    self.pendingInference = nil
                    self.scheduleBatch(pending.samples, isFinal: pending.isFinal)
                }
                self.finishIfPossible()
            }
        }
    }

    private func finishIfPossible() {
        guard stopRequested, !inferenceRunning, pendingInference == nil else { return }
        let completion = stopHandler
        stopHandler = nil
        completion?()
    }
}
