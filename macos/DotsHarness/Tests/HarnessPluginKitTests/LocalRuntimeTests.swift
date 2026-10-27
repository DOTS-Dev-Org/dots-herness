// Copyright (c) 2026 DOTS
// Native runtime tests.

import XCTest
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

final class LocalRuntimeTests: XCTestCase {
    func testHubSpecsRunTextGGUFAndStoreMediaAsDownloadOnly() {
        let gguf = HubFile(path: "q/model-Q4_K_M.gguf", size: 2_000_000_000, sha256: "abc")
        let text = HuggingFaceHub.spec(repo: "org/Model-GGUF", file: gguf, category: "coding")
        XCTAssertEqual(text.engine, .llama)
        XCTAssertEqual(text.filename, "hub/org--Model-GGUF/q/model-Q4_K_M.gguf")
        XCTAssertEqual(text.hubURL?.absoluteString, "https://huggingface.co/org/Model-GGUF")
        XCTAssertEqual(text.minMemoryGB, 3)
        XCTAssertEqual(HuggingFaceHub.spec(repo: "org/Wan-GGUF", file: gguf, category: "video").engine, .file)
        XCTAssertEqual(HuggingFaceHub.spec(repo: "org/Wan", file: nil, category: "video").engine, .repo)

        let search = HuggingFaceHub.searchURL(LocalModelCategory.named("video"), query: "wan").absoluteString
        XCTAssertTrue(search.contains("pipeline_tag=text-to-video") && search.contains("search=wan") && !search.contains("gguf"))
        XCTAssertTrue(HuggingFaceHub.searchURL(LocalModelCategory.named("coding"), query: "").absoluteString.contains("filter=gguf"))
        let weights = HuggingFaceHub.weights([HubFile(path: "README.md", size: 1, sha256: nil),
                                             HubFile(path: "a.safetensors", size: 1, sha256: nil), gguf])
        XCTAssertEqual(weights.map(\.path), [gguf.path, "a.safetensors"])
    }

    func testDiffusionBundlesNameEveryPartTheyLoad() {
        XCTAssertEqual(HuggingFaceHub.spec(repo: "org/SDXL", file: HubFile(path: "sdxl.safetensors", size: 1, sha256: nil),
                                           category: "image").engine, .diffusion)
        for preset in LocalDiffusion.presets {
            XCTAssertEqual(preset.engine, .diffusion)
            XCTAssertTrue(preset.runnable)
            XCTAssertEqual(preset.bytes, preset.components?.reduce(0) { $0 + $1.bytes })
            XCTAssertTrue(preset.components?.allSatisfy { $0.engine == .file && $0.sha256 != nil } ?? false)
        }
        let wan = LocalModelCatalog.spec(id: "wan21-t2v-13b-q4")
        XCTAssertEqual(wan?.category, "video")
        XCTAssertEqual(wan?.components?.compactMap(\.role), ["--diffusion-model", "--vae", "--t5xxl"])
    }

    func testCatalogIncludesLocalReasoningModel() {
        let ids = Set(LocalModelCatalog.models.map(\.id))
        XCTAssertTrue(ids.contains("qwen25-05b-q4"))
        XCTAssertTrue(ids.contains("llama32-1b-q4"))
        XCTAssertTrue(ids.contains("dsr1-15b-q4"))
        XCTAssertEqual(LocalModelCatalog.models.filter(\.reasoning).count, 2)
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

    func testLlamaRuntimeIsPinnedPerArchitecture() {
        let arm = LocalRuntime.llamaAsset(arch: "arm64")
        let intel = LocalRuntime.llamaAsset(arch: "x64")
        XCTAssertTrue(arm.url.absoluteString.hasSuffix("/\(LocalRuntime.llamaTag)/llama-\(LocalRuntime.llamaTag)-bin-macos-arm64.tar.gz"))
        XCTAssertEqual(arm.sha256.count, 64)
        XCTAssertEqual(intel.sha256.count, 64)
        XCTAssertNotEqual(arm.sha256, intel.sha256)
    }

    func testMLXVersionMatchesThePinnedPackage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("mlx-swift-lm\", exact: \"\(LocalRuntime.mlxVersion)\""))
        XCTAssertTrue(LocalRuntime.mlxServerBuild.hasPrefix(LocalRuntime.mlxVersion))
        XCTAssertTrue(LocalRuntime.mlxAsset.url.absoluteString.hasSuffix("/dotsmlx-\(LocalRuntime.mlxServerBuild)-macos-arm64.tar.gz"))
        XCTAssertEqual(LocalRuntime.mlxAsset.sha256.count, 64)
    }

    func testParsesGPUDevicesAndSkipsCPUAccelerators() {
        let output = """
        0.00.000.109 I srv  llama_server: initializing ...
        Available devices:
          MTL0: Apple M3 Pro (13639 MiB, 13639 MiB free)
          BLAS: Accelerate (0 MiB, 0 MiB free)
        """
        XCTAssertEqual(LocalRuntime.parseDevices(output), [LocalDevice(id: "MTL0", name: "Apple M3 Pro", memoryMiB: 13639)])
        XCTAssertTrue(LocalRuntime.parseDevices("Available devices:\n").isEmpty)
    }

    func testLlamaArgumentsFollowUserTuning() {
        let defaults = LocalRuntime.llamaArguments(modelPath: "/m.gguf", alias: "m", port: 1, context: 8192, settings: LocalRuntimeSettings())
        XCTAssertEqual(defaults, ["--model", "/m.gguf", "--host", "127.0.0.1", "--port", "1", "--ctx-size", "8192",
                                  "--alias", "m", "--jinja", "--parallel", "1", "--sleep-idle-seconds", "15", "--gpu-layers", "auto"])
        var tuned = LocalRuntimeSettings()
        tuned.gpuLayers = "20"
        tuned.threads = 6
        tuned.flashAttention = "on"
        tuned.kvCacheType = "q8_0"
        tuned.extraArgs = "--mlock  --ubatch-size 256"
        let arguments = LocalRuntime.llamaArguments(modelPath: "/m.gguf", alias: "m", port: 1, context: 4096, settings: tuned)
        XCTAssertEqual(Array(arguments.suffix(13)), ["--gpu-layers", "20", "--threads", "6", "--flash-attn", "on",
                                                     "--cache-type-k", "q8_0", "--cache-type-v", "q8_0",
                                                     "--mlock", "--ubatch-size", "256"])
    }

    func testAutomaticContextRespectsModelAndMemory() {
        let small = LocalModelCatalog.spec(id: "qwen25-05b-q4")!
        let large = LocalModelCatalog.spec(id: "gpt-oss-20b-q4")!
        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(LocalRuntime.automaticContext(for: small, memoryBytes: 64 * gib), 8_192)
        XCTAssertEqual(LocalRuntime.automaticContext(for: large, memoryBytes: 16 * gib), 16_384)
        XCTAssertEqual(LocalRuntime.automaticContext(for: large, memoryBytes: 32 * gib), 32_768)
    }

    func testSettingsDecodeToleratesMissingKeys() throws {
        let settings = try JSONDecoder().decode(LocalRuntimeSettings.self, from: Data(#"{"contextSize":4096}"#.utf8))
        XCTAssertEqual(settings.contextSize, 4096)
        XCTAssertEqual(settings.gpuLayers, "auto")
        XCTAssertTrue(settings.importedModels.isEmpty)
    }

    @MainActor
    func testCustomEndpointCarriesDeclaredModelAndContext() throws {
        let paths = Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = NativeProviderStore(paths: paths)
        let bare = try store.addCustom(name: "Ollama", prefix: "ollama", baseURL: "http://127.0.0.1:11434/v1", api: "openai", apiType: "chat", secret: "")
        let bareAccount = try store.addCustomAccount(endpoint: bare, secret: "")
        XCTAssertTrue(bareAccount.hasPlaceholderModel)
        XCTAssertNil(bareAccount.contextWindow)

        let declared = try store.addCustom(name: "Box", prefix: "box", baseURL: "http://127.0.0.1:1234/v1", api: "openai", apiType: "chat",
                                           secret: "", model: "qwen3:8b", contextWindow: 8192)
        let account = try store.addCustomAccount(endpoint: declared, secret: "")
        XCTAssertEqual(account.model, "qwen3:8b")
        XCTAssertFalse(account.hasPlaceholderModel)
        XCTAssertEqual(account.contextWindow, 8192)

        try store.updateCustom(endpoint: declared, name: "Box", prefix: "box", baseURL: declared.baseURL, api: "openai", apiType: "chat",
                               secret: nil, model: "qwen3:14b", contextWindow: 16_384)
        let reloaded = NativeProviderStore(paths: paths).state.accounts.first { $0.id == account.id }
        XCTAssertEqual(reloaded?.model, "qwen3:14b")
        XCTAssertEqual(reloaded?.contextWindow, 16_384)
    }

    func testProbeReadsLoadedContextPerModel() {
        let rows: [[String: Any]] = [
            ["id": "a", "loaded_context_length": 4096, "max_context_length": 32_768],
            ["id": "b", "max_context_length": 8192],
            ["id": "c"],
        ]
        XCTAssertEqual(LocalServerProbe.contexts(rows, id: "id", keys: ["loaded_context_length", "max_context_length"]), ["a": 4096, "b": 8192])
    }

    /// Downloads the pinned runtime and the smallest model, then serves it.
    ///   DOTS_LIVE_LOCAL=1 swift test --filter testLiveLlamaServesSmallestModel
    func testLiveLlamaServesSmallestModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOTS_LIVE_LOCAL"] == "1", "Set DOTS_LIVE_LOCAL=1 to download and serve a model.")
        let paths = Self.livePaths()
        let runtime = LocalRuntime(paths: paths, port: 18_799)
        defer { runtime.stop() }
        try await runtime.ensureRuntime()
        let devices = await runtime.devices()
        print("devices:", devices)
        let spec = LocalModelCatalog.spec(id: "qwen25-05b-q4")!
        try await runtime.downloadModel(spec)
        _ = try runtime.start(model: spec)
        let ready = await runtime.waitUntilReady()
        XCTAssertTrue(ready, runtime.logTail())
        let context = await runtime.servedContext()
        XCTAssertEqual(context, 8192)
        let reply = try await Self.chat(port: 18_799, model: spec.id)
        print("reply:", reply)
        XCTAssertFalse(reply.isEmpty)
    }

    ///   DOTS_LIVE_LOCAL=1 swift test --filter testLiveMLXServesSmallestModel
    func testLiveMLXServesSmallestModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOTS_LIVE_LOCAL"] == "1" && LocalRuntime.mlxSupported, "Set DOTS_LIVE_LOCAL=1 on Apple Silicon.")
        let paths = Self.livePaths()
        let runtime = LocalRuntime(paths: paths, port: 18_798)
        defer { runtime.stop() }
        // `swift test` builds dotsmlx beside the test bundle; mlx.metallib comes from
        // scripts/build-mlx-metallib.sh .build "$(swift build --show-bin-path)"
        // DOTS_LIVE_MLX_DOWNLOAD=1 serves with the published archive instead.
        if ProcessInfo.processInfo.environment["DOTS_LIVE_MLX_DOWNLOAD"] == "1" {
            runtime.mlxServerURL = runtime.mlxDirectory.appendingPathComponent("dotsmlx")
            try await runtime.ensureMLX()
        } else {
            runtime.mlxServerURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("dotsmlx")
        }
        let spec = LocalModelCatalog.spec(id: "mlx-qwen25-05b-4bit")!
        try await runtime.downloadModel(spec)
        XCTAssertTrue(runtime.isInstalled(spec))
        _ = try runtime.start(model: spec)
        let ready = await runtime.waitUntilReady()
        XCTAssertTrue(ready, runtime.logTail())
        let reply = try await Self.chat(port: 18_798, model: LocalRuntime.mlxModelID)
        print("reply:", reply)
        XCTAssertFalse(reply.isEmpty)
    }

    private static func chat(port: Int, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 16,
            "messages": [["role": "user", "content": "Say hi in one word."]],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }

    private static func paths(root: URL) -> SupportPaths {
        let paths = SupportPaths(
            root: root, plugins: root.appendingPathComponent("plugins"), presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings"), hostPatch: root.appendingPathComponent("patch"),
            trust: root.appendingPathComponent("trust"), models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime")
        )
        paths.ensure()
        return paths
    }

    private static func temporaryPaths() -> SupportPaths {
        paths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    /// Kept between runs so the live tests do not download gigabytes twice.
    private static func livePaths() -> SupportPaths {
        paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("dots-live-local"))
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
