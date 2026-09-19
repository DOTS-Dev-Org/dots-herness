// Copyright (c) 2026 DOTS
// Offline multilingual speech-to-text powered by whisper.cpp.

import Foundation
import PluginRuntime

/// Resolves `dots_whisper_transcribe` from libWhisperVoice.dylib on first use.
/// Keeping whisper behind dlopen means ggml/Metal are never mapped at launch
/// when the user does not use voice.
enum WhisperBridge {
    typealias TranscribeFn = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<Float>, Int32, Int32,
        UnsafeMutablePointer<CChar>, Int32
    ) -> Int32

    private static let entry: TranscribeFn? = {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [
            dir?.appendingPathComponent("libWhisperVoice.dylib").path,
            "libWhisperVoice.dylib",
        ].compactMap { $0 }
        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            guard let symbol = dlsym(handle, "dots_whisper_transcribe") else { continue }
            return unsafeBitCast(symbol, to: TranscribeFn.self)
        }
        return nil
    }()

    static func transcribe(modelPath: String, samples: [Float], threads: Int32) throws -> String {
        guard let entry else {
            throw NativeAgentError(AppCopy.text("voice.modelLoadFailed"))
        }
        var capacity = 8_192
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let code = modelPath.withCString { modelPointer in
                samples.withUnsafeBufferPointer { samplePointer in
                    entry(
                        modelPointer,
                        samplePointer.baseAddress!,
                        Int32(samplePointer.count),
                        threads,
                        &buffer,
                        Int32(capacity)
                    )
                }
            }
            switch code {
            case 0:
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            case let needed where needed > 0: capacity = Int(needed) + 16
            case -1: throw NativeAgentError(AppCopy.text("voice.modelLoadFailed"))
            default: throw NativeAgentError(AppCopy.text("voice.transcriptionFailed"))
            }
        }
    }
}

public struct LocalVoiceModel: Sendable, Equatable {
    public let id: String
    public let name: String
    public let filename: String
    public let url: URL?
    public let bytes: Int64
    public let sizeLabel: String
    public let sha256: String?

    public init(id: String, name: String, filename: String, url: URL?, bytes: Int64, sizeLabel: String, sha256: String? = nil) {
        self.id = id
        self.name = name
        self.filename = filename
        self.url = url
        self.bytes = bytes
        self.sizeLabel = sizeLabel
        self.sha256 = sha256
    }

    public static let whisperTinyQ5 = LocalVoiceModel(
        id: "whisper-tiny-q5",
        name: "Whisper Tiny Q5 (hızlı)",
        filename: "ggml-tiny-q5_1.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin?download=true"),
        bytes: 32_152_673,
        sizeLabel: VoiceCopy.whisperTinySize,
        sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
    )

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
        sizeLabel: VoiceCopy.nemotronSize,
        sha256: "a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae"
    )

    public static let custom = LocalVoiceModel(
        id: "custom-local",
        name: "Kullanıcı lokal modeli",
        filename: "voice-custom.bin",
        url: nil,
        bytes: 0,
        sizeLabel: VoiceCopy.customLocalSize
    )

    public static let model = whisperTinyQ5
}

public enum LocalVoiceModelState: Equatable, Sendable {
    case notInstalled
    case downloading
    case paused
    case installed
    case failed(String)

    public var isInstalled: Bool {
        self == .installed
    }

    public var title: String {
        switch self {
        case .notInstalled: return VoiceCopy.statusNotInstalled
        case .downloading: return VoiceCopy.statusDownloading
        case .paused: return VoiceCopy.statusPaused
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
        try await FileDownloader.download(
            from: url,
            to: modelURL,
            expected: selectedModel.bytes,
            sha256: selectedModel.sha256,
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

    /// The helper owns a process-lifetime context cache; kept for call-site parity.
    public func unloadModel() {}

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

        let threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        return try WhisperBridge.transcribe(
            modelPath: modelURL.path,
            samples: samples,
            threads: threads
        )
    }
}
