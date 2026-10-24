// Copyright (c) 2026 DOTS
// Offline multilingual speech-to-text powered by whisper.cpp.

import Foundation
import PluginRuntime

/// Resolves `dots_whisper_transcribe` from libWhisperVoice.dylib on first use.
/// Keeping whisper behind dlopen means ggml/Metal are never mapped at launch
/// when the user does not use voice. A development build carries the dylib
/// beside the app executable (run.sh); a release downloads it on first use.
enum WhisperBridge {
    typealias TranscribeFn = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<Float>, Int32, Int32,
        UnsafeMutablePointer<CChar>, Int32
    ) -> Int32
    typealias UnloadFn = @convention(c) () -> Void

    /// whisper.cpp version, then our own revision of the archive.
    static let build = "1.7.5-1"
    /// Built by scripts/package-whisper.sh and stored in the `dotsherness-assets` R2 bucket.
    static func asset(for arch: String) -> LocalRuntime.PinnedAsset? {
        switch arch {
        case "arm64":
            return LocalRuntime.PinnedAsset(
                url: URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/assets/downloads/whispervoice-\(build)-macos-arm64.tar.gz")!,
                size: 671_333,
                sha256: "c19d2287592ccc400a30895ee5e112a7f0d0526ddd1303dafa299bc67009ebfd"
            )
        case "x64", "x86_64":
            return LocalRuntime.PinnedAsset(
                url: URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/assets/downloads/whispervoice-\(build)-macos-x86_64.tar.gz")!,
                size: 756_044,
                sha256: "671bd149157b270f0f86381626e04b1732e5745ae8773d257dbfc96f3edb8b19"
            )
        default:
            return nil
        }
    }

    /// Keep Intel and Apple Silicon installs separate (Rosetta may run both on one Mac).
    static var directory: URL {
        let suffix = LocalRuntime.hostArch == "arm64" ? "" : "-x86_64"
        return SupportPaths.default().runtime.appendingPathComponent("whispervoice-\(build)\(suffix)", isDirectory: true)
    }

    private static var libraries: [String] {
        [
            ProcessInfo.processInfo.environment["DOTS_WHISPER_LIBRARY"],   // tests: a dylib outside the app bundle
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("libWhisperVoice.dylib").path,
            directory.appendingPathComponent("libWhisperVoice.dylib").path,
        ].compactMap { $0 }
    }

    /// Must run before the first `transcribe`: `entries` resolves only once.
    static func ensureInstalled() async throws {
        let fm = FileManager.default
        guard !libraries.contains(where: fm.fileExists(atPath:)) else { return }
        guard let asset = Self.asset(for: LocalRuntime.hostArch), asset.size > 0, !asset.sha256.isEmpty else {
            throw NativeAgentError(AppCopy.text("voice.modelLoadFailed"))
        }
        let archive = directory.appendingPathExtension("tar.gz")
        try await FileDownloader.download(from: asset.url, to: archive, expected: asset.size, sha256: asset.sha256)
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", directory.path]
        try tar.run()
        tar.waitUntilExit()
        try? fm.removeItem(at: archive)
        guard tar.terminationStatus == 0, libraries.contains(where: fm.fileExists(atPath:)) else {
            try? fm.removeItem(at: directory)
            throw NativeAgentError(AppCopy.text("voice.modelLoadFailed"))
        }
    }

    private static let entries: (transcribe: TranscribeFn, unload: UnloadFn)? = {
        for path in libraries + ["libWhisperVoice.dylib"] {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            guard let transcribe = dlsym(handle, "dots_whisper_transcribe"),
                  let unload = dlsym(handle, "dots_whisper_unload") else { continue }
            return (unsafeBitCast(transcribe, to: TranscribeFn.self), unsafeBitCast(unload, to: UnloadFn.self))
        }
        return nil
    }()

    /// Only call after `transcribe`: a first call here would dlopen whisper just to free nothing.
    static func unload() {
        entries?.unload()
    }

    static func transcribe(modelPath: String, samples: [Float], threads: Int32) throws -> String {
        guard let entry = entries?.transcribe else {
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
        name: "Whisper Tiny Q5",
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
        name: "Custom local model",
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
    /// Whisper weights stay in RAM after an utterance; they are released this long after the last one.
    static let idleReleaseDelay: Duration = .seconds(120)

    public let paths: SupportPaths
    public private(set) var selectedModel: LocalVoiceModel

    // Guards whisper calls and the release state below.
    private let lock = NSLock()
    private var whisperLoaded = false
    private var idleRelease: Task<Void, Never>?

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
        try await WhisperBridge.ensureInstalled()
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

    /// Frees the whisper weights now. Off the caller's thread: a running utterance holds `lock`.
    public func unloadModel() {
        Task.detached(priority: .utility) { [self] in
            releaseWhisper()
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
        // Covers a model installed by a release that still bundled whisper.
        try await WhisperBridge.ensureInstalled()
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
        defer {
            // Re-armed after every utterance, so rolling partials keep the weights loaded while speaking.
            idleRelease?.cancel()
            idleRelease = Task.detached(priority: .utility) { [self] in
                try? await Task.sleep(for: Self.idleReleaseDelay)
                guard !Task.isCancelled else { return }
                releaseWhisper()
            }
            lock.unlock()
        }

        let threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        whisperLoaded = true
        return try WhisperBridge.transcribe(
            modelPath: modelURL.path,
            samples: samples,
            threads: threads
        )
    }

    private func releaseWhisper() {
        lock.lock()
        defer { lock.unlock() }
        guard whisperLoaded else { return }
        WhisperBridge.unload()
        whisperLoaded = false
    }
}
