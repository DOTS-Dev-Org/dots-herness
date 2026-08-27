// Copyright (c) 2026 DOTS
// Offline multilingual speech-to-text powered by whisper.cpp.

import Foundation
import whisper
import PluginRuntime

public struct LocalVoiceModel: Sendable, Equatable {
    public let id: String
    public let name: String
    public let filename: String
    public let url: URL?
    public let bytes: Int64
    public let sizeLabel: String

    public init(id: String, name: String, filename: String, url: URL?, bytes: Int64, sizeLabel: String) {
        self.id = id
        self.name = name
        self.filename = filename
        self.url = url
        self.bytes = bytes
        self.sizeLabel = sizeLabel
    }

    public static let whisperLargeV3Turbo = LocalVoiceModel(
        id: "whisper-large-v3-turbo",
        name: "Whisper Large-v3-Turbo",
        filename: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true"),
        bytes: 574_041_195,
        sizeLabel: VoiceCopy.whisperTurboSize
    )

    public static let nemotron = LocalVoiceModel(
        id: "nemotron-3.5-asr",
        name: "Nemotron 3.5",
        filename: "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf",
        url: URL(string: "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/resolve/1c8deaecc64b91f034d73e08dd8b64625eb3395d/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf?download=true"),
        bytes: 741_548_352,
        sizeLabel: VoiceCopy.nemotronSize
    )

    public static let custom = LocalVoiceModel(
        id: "custom-local",
        name: "Kullanıcı lokal modeli",
        filename: "voice-custom.bin",
        url: nil,
        bytes: 0,
        sizeLabel: VoiceCopy.customLocalSize
    )

    public static let model = whisperLargeV3Turbo
}

public enum LocalVoiceModelState: Equatable, Sendable {
    case notInstalled
    case downloading
    case installed
    case failed(String)

    public var isInstalled: Bool {
        self == .installed
    }

    public var title: String {
        switch self {
        case .notInstalled: return VoiceCopy.statusNotInstalled
        case .downloading: return VoiceCopy.statusDownloading
        case .installed: return VoiceCopy.statusInstalled
        case .failed: return VoiceCopy.statusFailed
        }
    }
}

public final class LocalVoiceTranscriber: @unchecked Sendable {
    public static let model = LocalVoiceModel.model

    public let paths: SupportPaths
    public private(set) var selectedModel: LocalVoiceModel

    private let lock = NSLock()
    private var context: OpaquePointer?

    public init(paths: SupportPaths, model: LocalVoiceModel = .model) {
        self.paths = paths
        self.selectedModel = model
        paths.ensure()
    }

    public var modelURL: URL {
        paths.models.appendingPathComponent(selectedModel.filename)
    }

    public var isModelInstalled: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return false }
        return selectedModel.bytes > 0 ? size == selectedModel.bytes : true
    }

    public func configure(model: LocalVoiceModel) {
        unloadModel()
        selectedModel = model
    }

    public func ensureModel(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        guard !isModelInstalled else { return }
        guard let url = selectedModel.url else {
            throw NativeAgentError(AppCopy.text("voice.localModelFileRequired"))
        }
        unloadModel()
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try? FileManager.default.removeItem(at: modelURL)
        }
        try? FileManager.default.removeItem(at: modelURL.appendingPathExtension("part"))
        try await FileDownloader.download(
            from: url,
            to: modelURL,
            expected: selectedModel.bytes,
            progress: progress
        )
    }

    public func importModel(from source: URL) throws {
        guard selectedModel.id == LocalVoiceModel.custom.id else {
            throw NativeAgentError(AppCopy.text("voice.customModelRequired"))
        }
        unloadModel()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let size = try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw NativeAgentError(AppCopy.text("voice.invalidModelFile"))
        }
        try fm.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = modelURL.appendingPathExtension("part")
        try? fm.removeItem(at: temporaryURL)
        try fm.copyItem(at: source, to: temporaryURL)
        try? fm.removeItem(at: modelURL)
        try fm.moveItem(at: temporaryURL, to: modelURL)
    }

    public func deleteModel() throws {
        unloadModel()
        let fm = FileManager.default
        if fm.fileExists(atPath: modelURL.path) {
            try fm.removeItem(at: modelURL)
        }
        let temporaryURL = modelURL.appendingPathExtension("part")
        if fm.fileExists(atPath: temporaryURL.path) {
            try fm.removeItem(at: temporaryURL)
        }
    }

    public func unloadModel() {
        lock.lock()
        defer { lock.unlock() }
        if let context {
            whisper_free(context)
            self.context = nil
        }
    }

    public func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        let pcm = Self.resample(samples, from: sampleRate)
        guard pcm.count >= 1_600 else {
            throw NativeAgentError(AppCopy.text("voice.audioTooShort"))
        }

        guard isModelInstalled else {
            throw NativeAgentError(AppCopy.text("voice.modelNotReady"))
        }
        return try await Task.detached(priority: .userInitiated) { [self] in
            try transcribe16k(pcm)
        }.value
    }

    /// Converts microphone PCM to Whisper's required 16 kHz mono stream.
    public static func resample(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard sampleRate > 0, sampleRate != 16_000, samples.count > 1 else { return samples }

        // ponytail: linear resampling keeps this dependency-free; use AVAudioConverter only if quality profiling justifies it.
        let ratio = 16_000 / sampleRate
        let count = max(1, Int(Double(samples.count) * ratio))
        return (0..<count).map { index in
            let position = Double(index) / ratio
            let lower = min(Int(position), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }

    private func transcribe16k(_ samples: [Float]) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let ctx = try contextForModel()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.detect_language = true
        params.language = nil
        params.temperature = 0

        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard result == 0 else {
            throw NativeAgentError(AppCopy.text("voice.transcriptionFailed"))
        }

        return (0..<Int(whisper_full_n_segments(ctx))).compactMap { index in
            guard let text = whisper_full_get_segment_text(ctx, Int32(index)) else { return nil }
            return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func contextForModel() throws -> OpaquePointer {
        if let context { return context }

        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let context = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw NativeAgentError(AppCopy.text("voice.modelLoadFailed"))
        }
        self.context = context
        return context
    }

    deinit {
        unloadModel()
    }
}
