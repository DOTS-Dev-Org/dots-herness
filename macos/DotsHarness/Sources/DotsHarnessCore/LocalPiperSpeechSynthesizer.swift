// Copyright (c) 2026 DOTS
// Small offline Turkish TTS using the Piper voice through sherpa-onnx.
// sherpa-onnx and onnxruntime are not linked into the app. The runtime is fetched
// in the background the first time Turkish speech is requested after the speech
// model is installed, then opened with dlopen (see PiperRuntimeC).

import Foundation
import PiperRuntimeC
import PluginRuntime

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

/// Upstream shared libraries for the Piper voice. Archive pins are the SHA-256
/// checksums from sherpa-onnx v1.13.6 and onnxruntime-libs v1.27.1 Package.swift
/// (SwiftPM verifies the same values). Binary pins are the SHA-256 of the extracted
/// universal binaries; they are checked again before every dlopen, because the
/// archive pin only covers the download. Keep all values in sync with upstream.
public struct LocalSpeechRuntime: Sendable, Equatable {
    public struct Archive: Sendable, Equatable {
        public let url: URL
        public let bytes: Int64
        public let sha256: String
    }

    public let id: String
    public let sherpa: Archive
    public let onnxruntime: Archive
    /// SherpaOnnxC inside the sherpa-onnx xcframework.
    public let sherpaBinarySHA256: String
    /// onnxruntime inside the onnxruntime xcframework.
    public let onnxruntimeBinarySHA256: String

    public static let piper = LocalSpeechRuntime(
        id: "sherpa-1.13.6-ort-1.27.1",
        sherpa: Archive(
            url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.6-macos-shared.xcframework.zip")!,
            bytes: 3_567_548,
            sha256: "a04323813873d3f94691cc7c6890306467371ccef5cca7fdb1c8f1750d68f23f"
        ),
        onnxruntime: Archive(
            url: URL(string: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-macos-shared-xcframework-1.27.1.xcframework.zip")!,
            bytes: 51_164_437,
            sha256: "9d1d49b7c5ba7d5ccff048aff3f0c40431f8232b67259df9ab7f85d76e57cb75"
        ),
        sherpaBinarySHA256: "5f6f3dfe76a5372144847c13e900121fb6728b0064dfdd80229ad088a19d37f7",
        onnxruntimeBinarySHA256: "13fe4204ac19a0775b5a2db88f7430350c0f385e62d45405c20295a0486a4ed2"
    )
}

public final class LocalPiperSpeechSynthesizer: @unchecked Sendable {
    public static let model = LocalSpeechModel.turkishPiper
    public static let runtime = LocalSpeechRuntime.piper

    /// Layout of the extracted xcframeworks, relative to the runtime root.
    private static let sherpaSlice = "sherpa-onnx.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework/Versions/A"
    private static let onnxBinary = "onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/onnxruntime"

    public let paths: SupportPaths

    private let modelRoot: URL
    private let runtimeRoot: URL
    private let archiveURL: URL
    private let autoInstallRuntime: Bool
    private let lock = NSLock()
    private var engine: OpaquePointer?
    private var runtimeInstall: (id: UUID, task: Task<Void, Error>)?
    private var runtimeProgress: (@Sendable (FileDownloader.Progress) -> Void)?

    /// `autoInstallRuntime` lets `synthesize` fetch a missing runtime in the background.
    /// Tests pass false to stay offline.
    public init(paths: SupportPaths, autoInstallRuntime: Bool = true) {
        self.paths = paths
        self.autoInstallRuntime = autoInstallRuntime
        self.modelRoot = paths.models
            .appendingPathComponent("speech", isDirectory: true)
            .appendingPathComponent(Self.model.id, isDirectory: true)
        self.runtimeRoot = paths.runtime.appendingPathComponent(Self.runtime.id, isDirectory: true)
        self.archiveURL = paths.runtime.appendingPathComponent("\(Self.model.id).tar.bz2")
        paths.ensure()
    }

    deinit {
        if let engine { dots_piper_close(engine) }
    }

    /// Model files are on disk. Turkish speech also needs `isRuntimeInstalled`;
    /// `synthesize` fetches the runtime when it is missing.
    public var isModelInstalled: Bool { isModelFilesInstalled }

    public var isRuntimeInstalled: Bool {
        // fileExists follows symlinks, so a dangling libonnxruntime link reads as missing.
        let fm = FileManager.default
        return fm.fileExists(atPath: runtimeLibrary.path) && fm.fileExists(atPath: runtimeOnnxLink.path)
    }

    private var isModelFilesInstalled: Bool {
        let required = [
            modelRoot.appendingPathComponent(Self.model.modelFilename),
            modelRoot.appendingPathComponent("tokens.txt"),
            modelRoot.appendingPathComponent("espeak-ng-data", isDirectory: true),
        ]
        return required.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var runtimeLibrary: URL {
        runtimeRoot.appendingPathComponent("\(Self.sherpaSlice)/SherpaOnnxC")
    }

    private var runtimeOnnxLink: URL {
        runtimeRoot.appendingPathComponent("\(Self.sherpaSlice)/libonnxruntime.dylib")
    }

    public func ensureModel(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        if !isModelFilesInstalled {
            try await installModelFiles(progress: progress)
        }
        try await ensureRuntime(progress: progress)
    }

    private func installModelFiles(progress: (@Sendable (FileDownloader.Progress) -> Void)?) async throws {
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

    /// Installs the runtime, or joins the install that is already running.
    private func ensureRuntime(progress: (@Sendable (FileDownloader.Progress) -> Void)?) async throws {
        guard !isRuntimeInstalled else { return }
        try await startRuntimeInstall(progress: progress).value
    }

    /// Starts the runtime download unless one is running; concurrent callers share it.
    @discardableResult
    private func startRuntimeInstall(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) -> Task<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let progress { runtimeProgress = progress }
        if let running = runtimeInstall, !running.task.isCancelled { return running.task }

        let id = UUID()
        let task = Task.detached(priority: .utility) { [self] in
            defer { finishRuntimeInstall(id: id) }
            try await installRuntime()
        }
        runtimeInstall = (id, task)
        return task
    }

    private func finishRuntimeInstall(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard runtimeInstall?.id == id else { return }
        runtimeInstall = nil
        runtimeProgress = nil
    }

    private func reportRuntimeProgress(_ progress: FileDownloader.Progress) {
        lock.lock()
        let handler = runtimeProgress
        lock.unlock()
        handler?(progress)
    }

    private func installRuntime() async throws {
        let fm = FileManager.default
        // Staging folders left behind when the app quit mid-install.
        for url in (try? fm.contentsOfDirectory(at: paths.runtime, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("\(Self.runtime.id)-staging-") {
            try? fm.removeItem(at: url)
        }

        let staging = paths.runtime.appendingPathComponent("\(Self.runtime.id)-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for archive in [Self.runtime.sherpa, Self.runtime.onnxruntime] {
            let zip = paths.runtime.appendingPathComponent(archive.url.lastPathComponent)
            defer { try? fm.removeItem(at: zip) }
            try await FileDownloader.download(
                from: archive.url,
                to: zip,
                expected: archive.bytes,
                sha256: archive.sha256,
                progress: { [weak self] in self?.reportRuntimeProgress($0) }
            )
            // ditto keeps framework symlinks intact; unzip would not.
            try Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        }

        guard (try? FileDownloader.checksum(of: staging.appendingPathComponent("\(Self.sherpaSlice)/SherpaOnnxC"))) == Self.runtime.sherpaBinarySHA256,
              (try? FileDownloader.checksum(of: staging.appendingPathComponent(Self.onnxBinary))) == Self.runtime.onnxruntimeBinarySHA256 else {
            throw RouterError(AppCopy.text("download.checksumMismatch"))
        }

        // SherpaOnnxC resolves @rpath/libonnxruntime.dylib through @loader_path, so the
        // link sits next to it. The target is relative so it survives the move below.
        try fm.createSymbolicLink(
            atPath: staging.appendingPathComponent("\(Self.sherpaSlice)/libonnxruntime.dylib").path,
            withDestinationPath: "../../../../../\(Self.onnxBinary)"
        )

        try Task.checkCancellation()
        try? fm.removeItem(at: runtimeRoot)
        try fm.moveItem(at: staging, to: runtimeRoot)
    }

    public func deleteModel() throws {
        lock.lock()
        runtimeInstall?.task.cancel()
        runtimeInstall = nil
        if let engine { dots_piper_close(engine) }
        engine = nil
        lock.unlock()
        let fm = FileManager.default
        for url in [modelRoot, archiveURL, runtimeRoot] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    public func synthesize(_ text: String) async throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NativeAgentError(AppCopy.text("media.promptMissing")) }
        guard isModelFilesInstalled else { throw RouterError(AppCopy.text("voice.modelNotReady")) }
        guard isRuntimeInstalled else {
            // Fetch in the background. The caller falls back to the system voice for this request.
            if autoInstallRuntime { startRuntimeInstall() }
            throw RouterError(AppCopy.text("voice.modelNotReady"))
        }

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

    /// Called with `lock` held, so it must not take the lock itself.
    private func makeEngine() throws -> OpaquePointer {
        guard runtimeBinariesMatchPins() else {
            // Drop the tampered or stale runtime. The next request fetches it again.
            try? FileManager.default.removeItem(at: runtimeRoot)
            throw RouterError(AppCopy.text("speech.engineUnavailable"))
        }
        guard let engine = dots_piper_open(
            runtimeLibrary.path,
            modelRoot.appendingPathComponent(Self.model.modelFilename).path,
            modelRoot.appendingPathComponent("tokens.txt").path,
            modelRoot.appendingPathComponent("espeak-ng-data", isDirectory: true).path,
            Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        ) else {
            throw RouterError(AppCopy.text("speech.engineUnavailable"))
        }
        return engine
    }

    private func runtimeBinariesMatchPins() -> Bool {
        (try? FileDownloader.checksum(of: runtimeLibrary)) == Self.runtime.sherpaBinarySHA256
            && (try? FileDownloader.checksum(of: runtimeOnnxLink)) == Self.runtime.onnxruntimeBinarySHA256
    }

    private func synthesizeSynchronously(_ text: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        if engine == nil {
            engine = try makeEngine()
        }
        guard let engine else { throw RouterError(AppCopy.text("speech.engineUnavailable")) }

        var buffer: UnsafeMutablePointer<Float>?
        var sampleRate: Int32 = 0
        let count = dots_piper_generate(engine, text, 0, 0.96, &buffer, &sampleRate)
        defer { dots_piper_free_samples(buffer) }
        guard count > 0, sampleRate > 0, let buffer else {
            throw RouterError(AppCopy.text("speech.emptyOutput"))
        }

        let samples = Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
        let outputDirectory = paths.root.appendingPathComponent("generated-media", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let output = outputDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Self.wavData(samples: samples, sampleRate: Int(sampleRate)).write(to: output, options: .atomic)
        return output
    }

    private static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RouterError(AppCopy.text("speech.modelUnpackFailed"))
        }
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
