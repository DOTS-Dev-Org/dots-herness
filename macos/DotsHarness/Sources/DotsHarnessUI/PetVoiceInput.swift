// Copyright (c) 2026 DOTS
// Offline speech input used by the floating pet and composer.

import AVFoundation
import SwiftUI
import DotsHarnessCore

private final class AudioSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 16_000.0

    func reset(sampleRate: Double) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        self.sampleRate = sampleRate
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        lock.lock()
        if channelCount == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            samples.reserveCapacity(samples.count + frameCount)
            for frame in 0..<frameCount {
                var value: Float = 0
                for channel in 0..<channelCount {
                    value += channelData[channel][frame]
                }
                samples.append(value / Float(channelCount))
            }
        }
        lock.unlock()
    }

    func take() -> (samples: [Float], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        return (captured, sampleRate)
    }
}

enum PetVoiceState: Equatable {
    case idle
    case requesting
    case listening
    case transcribing
    case sending
    case failed(String)

    var icon: String {
        switch self {
        case .idle: return "mic"
        case .requesting: return "mic.badge.plus"
        case .listening: return "waveform"
        case .transcribing: return "ellipsis.circle"
        case .sending: return "sparkles"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .requesting, .listening: return .red
        case .transcribing, .sending: return .orange
        case .failed: return .yellow
        }
    }

    var isActive: Bool {
        switch self {
        case .requesting, .listening, .transcribing, .sending: return true
        case .idle, .failed: return false
        }
    }
}

@MainActor
final class PetVoiceInput: NSObject, ObservableObject {
    @Published private(set) var state: PetVoiceState = .idle
    @Published private(set) var transcript = ""

    private let model: AppModel
    private let onTranscript: ((String) -> Void)?
    private let audioEngine = AVAudioEngine()
    private let audioSamples = AudioSampleStore()
    private var sessionID = UUID()
    private var isTapInstalled = false
    private var errorResetTask: Task<Void, Never>?

    init(model: AppModel, onTranscript: ((String) -> Void)? = nil) {
        self.model = model
        self.onTranscript = onTranscript
        super.init()
    }

    var isListening: Bool {
        state == .requesting || state == .listening
    }

    func toggle() {
        switch state {
        case .requesting, .listening:
            stopListening(sendTranscript: true)
        case .transcribing, .sending:
            break
        case .idle, .failed:
            model.refreshVoiceModel()
            guard model.isVoiceReady else {
                model.requestVoiceInputSetup()
                return
            }
            startListening()
        }
    }

    func cancelListening() {
        guard isListening else { return }
        stopListening(sendTranscript: false)
    }

    func startListening() {
        guard state != .sending, state != .transcribing else { return }
        model.refreshVoiceModel()
        guard model.isVoiceReady else {
            model.requestVoiceInputSetup()
            return
        }

        errorResetTask?.cancel()
        transcript = ""
        state = .requesting

        let currentSession = UUID()
        sessionID = currentSession
        requestMicrophoneAuthorization(for: currentSession)
    }

    private func requestMicrophoneAuthorization(for currentSession: UUID) {
        guard sessionID == currentSession else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording(for: currentSession)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == currentSession else { return }
                    if granted {
                        self.beginRecording(for: currentSession)
                    } else {
                        self.fail(AppCopy.text("voice.microphonePermissionDenied"))
                    }
                }
            }
        case .denied, .restricted:
            fail(AppCopy.text("voice.microphonePermissionDisabled"))
        @unknown default:
            fail(AppCopy.text("voice.microphonePermissionUnknown"))
        }
    }

    private func beginRecording(for currentSession: UUID) {
        guard sessionID == currentSession else { return }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
            fail(AppCopy.text("voice.microphoneUnavailable"))
            return
        }

        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        audioSamples.reset(sampleRate: recordingFormat.sampleRate)
        let audioSamples = audioSamples
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { buffer, _ in
            audioSamples.append(buffer)
        }
        isTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            state = .listening
        } catch {
            fail(AppCopy.format("voice.microphoneStartFailed", error.localizedDescription))
        }
    }

    private func stopListening(sendTranscript: Bool) {
        guard isListening else { return }

        stopAudioSession()
        let capture = audioSamples.take()
        guard sendTranscript, !capture.samples.isEmpty else {
            transcript = ""
            state = .idle
            return
        }

        transcript = ""
        state = .transcribing
        let model = model
        Task { @MainActor [weak self] in
            do {
                let text = try await model.transcribeVoice(
                    samples: capture.samples,
                    sampleRate: capture.sampleRate
                )
                guard !text.isEmpty else {
                    self?.fail(AppCopy.text("voice.noSpeechDetected"))
                    return
                }
                guard let self else { return }
                self.transcript = text

                if let onTranscript {
                    onTranscript(text)
                    self.transcript = ""
                    self.state = .idle
                    return
                }

                self.state = .sending
                await model.bridge.send(text: text, mode: .queue)
                self.transcript = ""
                self.state = .idle
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.fail(AppCopy.format("voice.audioProcessingFailed", error.localizedDescription))
            }
        }
    }

    private func stopAudioSession() {
        sessionID = UUID()
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    private func fail(_ message: String) {
        stopAudioSession()
        transcript = ""
        state = .failed(message)

        errorResetTask?.cancel()
        errorResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.state = .idle
        }
    }
}
