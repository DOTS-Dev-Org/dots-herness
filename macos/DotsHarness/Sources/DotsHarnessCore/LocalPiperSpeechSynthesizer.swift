// Copyright (c) 2026 DOTS
// Small offline Turkish TTS using the Piper voice through sherpa-onnx.

import Foundation
import PluginRuntime
import SherpaOnnx

public struct LocalSpeechModel: Sendable, Equatable {
    public let id: String
    public let name: String
    public let archiveURL: URL
    public let archiveBytes: Int64
    public let archiveSHA256: String
    public let modelFilename: String

    public static let turkishPiper = LocalSpeechModel(
        id: "vits-piper-tr_TR-dfki-medium-int8",
        name: "Piper Türkçe (int8)",
        archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-tr_TR-dfki-medium-int8.tar.bz2")!,
        archiveBytes: 21_135_582,
        archiveSHA256: "6cda7bc029b7d5549a80439c51beb4c40c42df4b4614f01a8c61deb2fc859aa2",
        modelFilename: "tr_TR-dfki-medium.onnx"
    )
}

public final class LocalPiperSpeechSynthesizer: @unchecked Sendable {
    public static let model = LocalSpeechModel.turkishPiper

    public let paths: SupportPaths

    private let modelRoot: URL
    private let archiveURL: URL
    private let lock = NSLock()
    private var engine: SherpaOnnxOfflineTtsWrapper?

    public init(paths: SupportPaths) {
        self.paths = paths
        self.modelRoot = paths.models
            .appendingPathComponent("speech", isDirectory: true)
            .appendingPathComponent(Self.model.id, isDirectory: true)
        self.archiveURL = paths.runtime.appendingPathComponent("\(Self.model.id).tar.bz2")
        paths.ensure()
    }

    public var isModelInstalled: Bool {
        let required = [
            modelRoot.appendingPathComponent(Self.model.modelFilename),
            modelRoot.appendingPathComponent("tokens.txt"),
            modelRoot.appendingPathComponent("espeak-ng-data", isDirectory: true),
        ]
        return required.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func ensureModel(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        if isModelInstalled { return }

        try await FileDownloader.download(
            from: Self.model.archiveURL,
            to: archiveURL,
            expected: Self.model.archiveBytes,
            sha256: Self.model.archiveSHA256,
            progress: progress
        )

        let fm = FileManager.default
        let staging = paths.runtime.appendingPathComponent("\(Self.model.id)-staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let extractor = Process()
        extractor.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extractor.arguments = ["-xjf", archiveURL.path, "-C", staging.path]
        extractor.standardOutput = Pipe()
        extractor.standardError = Pipe()
        try extractor.run()
        extractor.waitUntilExit()

        let extractedRoot = staging.appendingPathComponent(Self.model.id, isDirectory: true)
        guard extractor.terminationStatus == 0,
              FileManager.default.fileExists(atPath: extractedRoot.appendingPathComponent(Self.model.modelFilename).path),
              FileManager.default.fileExists(atPath: extractedRoot.appendingPathComponent("tokens.txt").path),
              FileManager.default.fileExists(atPath: extractedRoot.appendingPathComponent("espeak-ng-data", isDirectory: true).path) else {
            try? fm.removeItem(at: staging)
            throw RouterError(AppCopy.text("speech.modelUnpackFailed"))
        }

        try? fm.removeItem(at: modelRoot)
        try fm.createDirectory(at: modelRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: extractedRoot, to: modelRoot)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: archiveURL)
    }

    public func deleteModel() throws {
        lock.lock()
        engine = nil
        lock.unlock()
        let fm = FileManager.default
        if fm.fileExists(atPath: modelRoot.path) { try fm.removeItem(at: modelRoot) }
        if fm.fileExists(atPath: archiveURL.path) { try fm.removeItem(at: archiveURL) }
    }

    public func synthesize(_ text: String) async throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NativeAgentError(AppCopy.text("media.promptMissing")) }
        guard isModelInstalled else { throw RouterError(AppCopy.text("voice.modelNotReady")) }

        return try await Task.detached(priority: .userInitiated) { [self] in
            try synthesizeSynchronously(text)
        }.value
    }

    public static func wavData(samples: [Float], sampleRate: Int) throws -> Data {
        guard sampleRate > 0, samples.count <= (Int(UInt32.max) - 36) / 2 else {
            throw RouterError(AppCopy.text("speech.invalidAudio"))
        }

        var data = Data(capacity: 44 + samples.count * 2)
        data.append(Data("RIFF".utf8))
        appendLittleEndian(UInt32(36 + samples.count * 2), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(UInt32(samples.count * 2), to: &data)

        for sample in samples {
            let normalized = sample.isFinite ? max(-1, min(1, sample)) : 0
            let pcm = normalized <= -1 ? Int16.min : Int16((normalized * Float(Int16.max)).rounded())
            appendLittleEndian(pcm, to: &data)
        }
        return data
    }

    private func makeEngine() -> SherpaOnnxOfflineTtsWrapper? {
        let vits = sherpaOnnxOfflineTtsVitsModelConfig(
            model: modelRoot.appendingPathComponent(Self.model.modelFilename).path,
            tokens: modelRoot.appendingPathComponent("tokens.txt").path,
            dataDir: modelRoot.appendingPathComponent("espeak-ng-data", isDirectory: true).path,
            noiseScale: 0.667,
            noiseScaleW: 0.8,
            lengthScale: 1.0
        )
        let model = sherpaOnnxOfflineTtsModelConfig(
            vits: vits,
            numThreads: min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)),
            provider: "cpu"
        )
        var config = sherpaOnnxOfflineTtsConfig(model: model)
        let wrapper = withUnsafePointer(to: &config) { SherpaOnnxOfflineTtsWrapper(config: $0) }
        return wrapper.tts == nil ? nil : wrapper
    }

    private func synthesizeSynchronously(_ text: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        if engine == nil {
            engine = makeEngine()
        }
        guard let engine else { throw RouterError(AppCopy.text("speech.engineUnavailable")) }

        let audio = engine.generate(text: text, sid: 0, speed: 0.96)
        guard audio.n > 0, audio.sampleRate > 0 else {
            throw RouterError(AppCopy.text("speech.emptyOutput"))
        }

        let outputDirectory = paths.root.appendingPathComponent("generated-media", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let output = outputDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Self.wavData(samples: audio.samples, sampleRate: Int(audio.sampleRate)).write(to: output, options: .atomic)
        return output
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
