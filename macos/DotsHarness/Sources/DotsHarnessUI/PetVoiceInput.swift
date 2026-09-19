// Copyright (c) 2026 DOTS
// Live microphone input shared by the floating pet and composer.

import AVFoundation
import SwiftUI
import DotsHarnessCore

private final class AudioPCMChunker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var sourceRate = 16_000.0
    private let outputChunkSamples = 2_560 // 160 ms at 16 kHz

    func reset(sourceRate: Double) {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        self.sourceRate = sourceRate
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard buffer.frameLength > 0, buffer.format.channelCount > 0 else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)

        if let channels = buffer.floatChannelData {
            for frame in 0..<frameCount {
                var value: Float = 0
                for channel in 0..<channelCount {
                    value += channels[channel][frame]
                }
                mono[frame] = value / Float(channelCount)
            }
        } else if let channels = buffer.int16ChannelData {
            for frame in 0..<frameCount {
                var value: Float = 0
                for channel in 0..<channelCount {
                    value += Float(channels[channel][frame]) / 32_768
                }
                mono[frame] = value / Float(channelCount)
            }
        } else {
            return []
        }

        lock.lock()
        let rate = sourceRate
        pending.append(contentsOf: LocalVoiceTranscriber.resample(mono, from: rate))
        var chunks: [[Float]] = []
        while pending.count >= outputChunkSamples {
            // ponytail: small callback buffers make removeFirst cheaper than a second ring-buffer type.
            chunks.append(Array(pending.prefix(outputChunkSamples)))
            pending.removeFirst(outputChunkSamples)
        }
        lock.unlock()
        return chunks
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let remaining = pending
        pending.removeAll(keepingCapacity: true)
        return remaining
    }
}

// AVAudioEngine invokes taps on its realtime queue. The tap only normalizes
// audio and enqueues 160 ms PCM blocks; model/network work stays off it.
private func installAudioTap(
    on inputNode: AVAudioInputNode,
    format: AVAudioFormat,
    chunker: AudioPCMChunker,
    session: VoiceStreamingSession
) {
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, _ in
        for chunk in chunker.append(buffer) {
            session.push(chunk)
        }
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
    private let audioChunker = AudioPCMChunker()
    private var voiceSession: VoiceStreamingSession?
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
        voiceSession?.cancel()
        voiceSession = nil
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
            prepareStreamingSession(for: currentSession)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == currentSession else { return }
                    if granted {
                        self.prepareStreamingSession(for: currentSession)
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

    private func prepareStreamingSession(for currentSession: UUID) {
        guard sessionID == currentSession else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await model.makeVoiceStreamingSession(
                    onUpdate: { [weak self] update in
                        Task { @MainActor in
                            self?.handle(update, for: currentSession)
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.sessionID == currentSession else { return }
                            self.fail(AppCopy.format("voice.audioProcessingFailed", error.localizedDescription))
                        }
                    }
                )
                guard self.sessionID == currentSession, self.state == .requesting else {
                    session.cancel()
                    return
                }
                self.voiceSession = session
                self.beginRecording(for: currentSession, session: session)
            } catch is CancellationError {
                guard self.sessionID == currentSession else { return }
                self.state = .idle
            } catch {
                guard self.sessionID == currentSession else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func beginRecording(for currentSession: UUID, session: VoiceStreamingSession) {
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

        audioChunker.reset(sourceRate: recordingFormat.sampleRate)
        installAudioTap(on: inputNode, format: recordingFormat, chunker: audioChunker, session: session)
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

        let currentSession = sessionID
        stopAudioCapture()

        guard sendTranscript, let session = voiceSession else {
            sessionID = UUID()
            voiceSession?.cancel()
            voiceSession = nil
            _ = audioChunker.drain()
            transcript = ""
            state = .idle
            return
        }

        let remaining = audioChunker.drain()
        if !remaining.isEmpty { session.push(remaining) }
        transcript = ""
        state = .transcribing
        session.stop { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionID == currentSession else { return }
                self.voiceSession = nil
                if self.state == .transcribing { self.state = .idle }
            }
        }
    }

    private func handle(_ update: VoiceTranscriptUpdate, for currentSession: UUID) {
        guard sessionID == currentSession else { return }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if update.isFinal {
            transcript = ""
            if let onTranscript {
                onTranscript(text)
            } else {
                state = .sending
                model.send(text: text, mode: .queue)
                state = .idle
            }
        } else {
            transcript = text
        }
    }

    private func stopAudioCapture() {
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    private func fail(_ message: String) {
        sessionID = UUID()
        stopAudioCapture()
        voiceSession?.cancel()
        voiceSession = nil
        _ = audioChunker.drain()
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
