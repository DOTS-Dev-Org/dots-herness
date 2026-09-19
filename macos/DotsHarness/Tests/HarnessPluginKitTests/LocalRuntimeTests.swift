// Copyright (c) 2026 DOTS
// Native runtime tests.

import XCTest
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

final class LocalRuntimeTests: XCTestCase {
    func testCatalogIncludesLocalReasoningModel() {
        let ids = Set(LocalModelCatalog.models.map(\.id))
        XCTAssertTrue(ids.contains("qwen25-05b-q4"))
        XCTAssertTrue(ids.contains("llama32-1b-q4"))
        XCTAssertTrue(ids.contains("dsr1-15b-q4"))
        XCTAssertEqual(LocalModelCatalog.models.filter(\.reasoning).count, 1)
        XCTAssertTrue(LocalModelCatalog.spec(id: "dsr1-15b-q4")?.url.absoluteString.contains("huggingface.co") == true)
    }

    func testRouterNodeMapsProviderNodePayload() {
        let node = RouterNode(from: [
            "id": .string("openai-compatible-chat-abc"),
            "type": .string("openai-compatible"),
            "name": .string("Ollama"),
            "prefix": .string("local"),
            "apiType": .string("chat"),
            "baseUrl": .string("http://127.0.0.1:11434/v1"),
        ])
        XCTAssertEqual(node.prefix, "local")
        XCTAssertEqual(node.baseURL, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(node.apiType, "chat")
    }

    func testPicksMacOSArm64LlamaAsset() throws {
        let json = JSONValue.object([
            "tag_name": .string("b10488"),
            "assets": .array([
                .object([
                    "name": .string("llama-b10488-bin-ubuntu-x64.tar.gz"),
                    "size": .number(1),
                    "browser_download_url": .string("https://example.com/ubuntu"),
                ]),
                .object([
                    "name": .string("llama-b10488-bin-macos-arm64.tar.gz"),
                    "size": .number(11_087_008),
                    "browser_download_url": .string("https://example.com/macos-arm64"),
                ]),
                .object([
                    "name": .string("llama-b10488-bin-macos-x64.tar.gz"),
                    "size": .number(11_392_805),
                    "browser_download_url": .string("https://example.com/macos-x64"),
                ]),
            ]),
        ])
        let asset = try LocalRuntime.macAsset(from: json, arch: "arm64")
        XCTAssertEqual(asset.tag, "b10488")
        XCTAssertEqual(asset.url.absoluteString, "https://example.com/macos-arm64")
        XCTAssertEqual(asset.size, 11_087_008)
    }

    func testDownloaderSkipsCompleteFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarness-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("model.gguf")
        let payload = Data(repeating: 7, count: 128)
        try payload.write(to: dest)
        try await FileDownloader.download(
            from: URL(string: "https://example.invalid/missing.gguf")!,
            to: dest,
            expected: 128
        )
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, 128)
        try? FileManager.default.removeItem(at: dir)
    }

    func testDownloadProgressCarriesSpeed() {
        let progress = FileDownloader.Progress(received: 256, expected: 1_024, bytesPerSecond: 128)

        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(progress.bytesPerSecond, 128)
    }

    func testVoiceDownloadCanBePaused() {
        XCTAssertFalse(LocalVoiceModelState.paused.isInstalled)
        XCTAssertEqual(LocalVoiceModelState.paused.title, VoiceCopy.statusPaused)
    }

    func testDownloaderRejectsExistingFileWithBadChecksum() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarness-dl-checksum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("runtime.tar.gz")
        try Data(repeating: 3, count: 64).write(to: dest)

        var didThrow = false
        do {
            try await FileDownloader.download(
                from: URL(string: "https://example.invalid/missing.tar.gz")!,
                to: dest,
                expected: 64,
                sha256: String(repeating: "0", count: 64)
            )
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        try? FileManager.default.removeItem(at: dir)
    }

    func testLocalVoiceResamplesToWhisperRate() {
        let samples = LocalVoiceTranscriber.resample([0, 1, 0, -1], from: 8_000)

        XCTAssertEqual(samples.count, 8)
        XCTAssertEqual(samples[2], 1, accuracy: 0.0001)
        XCTAssertEqual(samples[6], -1, accuracy: 0.0001)
    }

    func testVoiceInputCatalogIncludesLocalAndAPIChoices() {
        XCTAssertEqual(
            Set(VoiceInputProvider.allCases),
            [.whisperTinyQ5, .whisperLargeV3Turbo, .nemotron, .customLocal, .api]
        )
        XCTAssertEqual(LocalVoiceModel.whisperLargeV3Turbo.bytes, 574_041_195)
        XCTAssertEqual(LocalVoiceModel.whisperLargeV3Turbo.filename, "ggml-large-v3-turbo-q5_0.bin")
        XCTAssertTrue(LocalVoiceModel.whisperLargeV3Turbo.url?.host == "huggingface.co")
        XCTAssertEqual(LocalVoiceModel.nemotron.bytes, 741_548_352)
        XCTAssertEqual(LocalVoiceModel.nemotron.filename, "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf")
        XCTAssertTrue(LocalVoiceModel.nemotron.url?.absoluteString.contains("1c8deaecc64b91f034d73e08dd8b64625eb3395d") == true)
        XCTAssertTrue(VoiceInputProvider.whisperLargeV3Turbo.isFileBacked)
        XCTAssertTrue(VoiceInputProvider.nemotron.isFileBacked)
        XCTAssertFalse(VoiceInputProvider.api.isFileBacked)
        XCTAssertTrue(VoiceInputProvider.whisperLargeV3Turbo.sizeLabel.contains("547 MiB"))
        XCTAssertTrue(VoiceInputProvider.nemotron.sizeLabel.contains("742"))
        XCTAssertFalse(VoiceInputProvider.api.sizeLabel.isEmpty)
        XCTAssertFalse(VoiceInputProvider.api.sizeLabel.contains("MiB"))
        XCTAssertFalse(VoiceInputProvider.api.sizeLabel.contains("MB"))
        XCTAssertFalse(VoiceCopy.downloadAction.isEmpty)
    }

    func testWhisperTinyQ5MetadataIsPinned() {
        XCTAssertEqual(LocalVoiceModel.whisperTinyQ5.filename, "ggml-tiny-q5_1.bin")
        XCTAssertEqual(LocalVoiceModel.whisperTinyQ5.bytes, 32_152_673)
        XCTAssertEqual(LocalVoiceModel.whisperTinyQ5.sha256, "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7")
        XCTAssertTrue(LocalVoiceModel.whisperTinyQ5.url?.absoluteString.contains("huggingface.co/ggerganov/whisper.cpp") == true)
    }

    func testVoiceVADKeepsBreathGapAndEndpointsAfter800Milliseconds() {
        let detector = VoiceActivityDetector()
        let speech = Array(repeating: Float(0.08), count: VoiceStreamTuning().frameSamples)
        let silence = Array(repeating: Float(0), count: VoiceStreamTuning().frameSamples)

        for _ in 0..<12 { _ = detector.consume(speech) }
        let breathEvents = (0..<20).flatMap { _ in detector.consume(silence) }
        XCTAssertFalse(breathEvents.contains { if case .utteranceEnded = $0 { true } else { false } })

        let endpointEvents = (0..<20).flatMap { _ in detector.consume(silence) }
        XCTAssertTrue(endpointEvents.contains { if case .utteranceEnded = $0 { true } else { false } })
    }

    func testVoiceVADFlushEndsRemainingSpeech() {
        let detector = VoiceActivityDetector()
        let speech = Array(repeating: Float(0.08), count: VoiceStreamTuning().frameSamples * 12)
        _ = detector.consume(speech)

        let events = detector.flush()
        XCTAssertTrue(events.contains { if case .utteranceEnded = $0 { true } else { false } })
    }

    func testNemotronMacRuntimeAssetsArePinnedPerArchitecture() throws {
        let arm = try NemotronRuntime.macAsset(arch: "arm64")
        XCTAssertTrue(arm.url.absoluteString.contains("macos-aarch64-metal"))
        XCTAssertEqual(arm.bytes, 3_465_028)
        XCTAssertEqual(arm.sha256, "f1dff4f9dd9c96214f8cb78b982812459132df8a4ad1a42409fd94de4a366244")
        XCTAssertEqual(arm.sha256.count, 64)

        let intel = try NemotronRuntime.macAsset(arch: "x64")
        XCTAssertTrue(intel.url.absoluteString.contains("macos-x86_64-cpu"))
        XCTAssertEqual(intel.bytes, 3_618_245)
        XCTAssertEqual(intel.sha256, "042a4612e07460fab6a39b5d862aa1e39d0ac3eaedfdb979f3f5fc12de510c20")
    }

    func testVoiceAPIConfigurationNeedsEndpointAndModelOnly() {
        XCTAssertTrue(VoiceAPIConfiguration(
            endpoint: "http://127.0.0.1:8080/v1",
            apiKey: "",
            model: "nemotron-3.5-asr-streaming-0.6b"
        ).isConfigured)
        XCTAssertFalse(VoiceAPIConfiguration(endpoint: " ", apiKey: "key", model: "whisper-1").isConfigured)
        XCTAssertFalse(VoiceAPIConfiguration(endpoint: "http://localhost", apiKey: "", model: " ").isConfigured)
    }

    func testLocalVoiceModelStateFollowsFilePresence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessVoice-\(UUID().uuidString)", isDirectory: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
        let transcriber = LocalVoiceTranscriber(paths: paths)
        XCTAssertFalse(transcriber.isModelInstalled)

        FileManager.default.createFile(atPath: transcriber.modelURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: transcriber.modelURL)
        try handle.truncate(atOffset: UInt64(LocalVoiceTranscriber.model.bytes - 1))
        try handle.close()
        XCTAssertFalse(transcriber.isModelInstalled)

        FileManager.default.createFile(atPath: transcriber.modelURL.path, contents: Data())
        let handle2 = try FileHandle(forWritingTo: transcriber.modelURL)
        try handle2.truncate(atOffset: UInt64(LocalVoiceTranscriber.model.bytes))
        try handle2.close()
        XCTAssertTrue(transcriber.isModelInstalled)

        let partial = transcriber.modelURL.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: Data([1, 2, 3]))
        try transcriber.deleteModel()
        XCTAssertFalse(transcriber.isModelInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testNemotronDeleteKeepsRuntimeCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessNemotron-\(UUID().uuidString)", isDirectory: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
        let runtime = NemotronRuntime(paths: paths)
        try FileManager.default.createDirectory(at: paths.runtime.appendingPathComponent("nemo-speech"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: runtime.modelURL.path, contents: Data([1]))
        FileManager.default.createFile(atPath: runtime.modelURL.appendingPathExtension("part").path, contents: Data([2]))

        try runtime.deleteModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.modelURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.modelURL.appendingPathExtension("part").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.runtime.appendingPathComponent("nemo-speech").path))
        try? FileManager.default.removeItem(at: root)
    }

    func testLocalSpeechDetectsTurkishAndEnglish() {
        XCTAssertEqual(
            LocalSpeechSynthesizer.languageCode(for: "Merhaba, nasılsın?"),
            "tr-TR"
        )
        XCTAssertEqual(
            LocalSpeechSynthesizer.languageCode(for: "Hello, how are you?"),
            "en-US"
        )
    }

    func testLocalPiperSpeechModelAndWAVOutput() throws {
        XCTAssertEqual(LocalSpeechModel.turkishPiper.archiveBytes, 21_135_582)
        XCTAssertEqual(LocalSpeechModel.turkishPiper.modelFilename, "tr_TR-dfki-medium.onnx")
        XCTAssertTrue(LocalSpeechModel.turkishPiper.archiveURL.host == "github.com")

        let wav = try LocalPiperSpeechSynthesizer.wavData(samples: [-1, 0, 1], sampleRate: 22_050)
        XCTAssertEqual(Data(wav.prefix(4)), Data("RIFF".utf8))
        XCTAssertEqual(Data(wav.dropFirst(8).prefix(4)), Data("WAVE".utf8))
        XCTAssertEqual(wav.count, 50)
    }

}

@MainActor
final class LocalRuntimeMainActorTests: XCTestCase {
    func testSanitizedPrefixOnMainActorController() {
        let router = RouterController()
        XCTAssertEqual(router.sanitizedPrefix("Ollama Local"), "ollama-local")
        XCTAssertEqual(router.sanitizedPrefix("Local LLM!!"), "local-llm")
        XCTAssertEqual(router.sanitizedPrefix("My API 2"), "my-api-2")
    }
}
