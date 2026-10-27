// Copyright (c) 2026 DOTS
// stable-diffusion.cpp: local image (sd-server) and video (sd-cli) generation.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PluginRuntime

public enum LocalDiffusion {
    /// Pinned with its checksum like llama.cpp: the binaries are executed.
    /// The release is a universal (arm64 + x86_64) Metal build.
    public static let tag = "master-963-46362fc"
    static let asset = LocalRuntime.PinnedAsset(
        url: URL(string: "https://github.com/leejet/stable-diffusion.cpp/releases/download/master-963-46362fc/sd-master-46362fc-bin-Darwin-macOS-26.6.2-arm64.zip")!,
        size: 35_213_317,
        sha256: "c7064eccf0833246d31fa059121d32c6233ccb597f5509c10c3b0f8a77e0c5f4"
    )
    public static let port = 18766
    public static var baseURL: String { "http://127.0.0.1:\(port)/v1" }
    /// Frame rate the rendered frames are encoded at; Wan 2.1 is trained at 16.
    static let videoFPS: Int32 = 16

    /// The started diffusion model. While set, `/imagegen`, `/videogen` and the
    /// media studio render with it instead of a provider.
    @MainActor public static var active: (runtime: LocalRuntime, spec: LocalModelSpec)?

    public static let presets: [LocalModelSpec] = [
        bundle(
            id: "sd-turbo", name: "SD-Turbo", category: "image", memory: 8,
            notes: AppCopy.text("localModel.sdTurboNote"),
            args: ["--steps", "1", "--cfg-scale", "1", "-W", "512", "-H", "512"],
            parts: [part("stabilityai/sd-turbo", "sd_turbo.safetensors", 5_214_561_328,
                         "3f067a1b943cf162f2b8f8588f6cf5824bd5b4c7d1d88d87164b9ca123616549", role: nil)]
        ),
        bundle(
            id: "flux1-schnell-q4", name: "FLUX.1 schnell", category: "image", memory: 16,
            notes: AppCopy.text("localModel.fluxNote"),
            args: ["--steps", "4", "--cfg-scale", "1", "--sampling-method", "euler", "-W", "1024", "-H", "1024"],
            parts: [
                part("second-state/FLUX.1-schnell-GGUF", "flux1-schnell-Q4_0.gguf", 6_688_845_536,
                     "b338a7ab5c81600a54be46c4cf950edb3761a52ae163e419beafd250976fb566", role: "--diffusion-model"),
                part("second-state/FLUX.1-schnell-GGUF", "ae.safetensors", 335_304_388,
                     "afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38", role: "--vae"),
                part("second-state/FLUX.1-schnell-GGUF", "clip_l-Q8_0.gguf", 130_769_600,
                     "59cbe002c3e75d2b89d38787e81d12fb4e512fd76176884c470737ad87a1d309", role: "--clip_l"),
                part("second-state/FLUX.1-schnell-GGUF", "t5xxl-Q4_K.gguf", 2_752_844_256,
                     "8b465525114b89011303969a035ef7e335821f13a32c4f31212912fb6511e128", role: "--t5xxl"),
            ]
        ),
        bundle(
            id: "wan21-t2v-13b-q4", name: "Wan 2.1 T2V 1.3B", category: "video", memory: 12,
            notes: AppCopy.text("localModel.wanNote"),
            // ponytail: 832×480×33 ran ~110 s per step on a 19 GB Mac; this size keeps a clip to minutes. Raise for bigger GPUs.
            args: ["--cfg-scale", "6", "--sampling-method", "euler", "--steps", "15", "-W", "512", "-H", "288",
                   "--video-frames", "17", "--flow-shift", "3"],
            parts: [
                part("samuelchristlie/Wan2.1-T2V-1.3B-GGUF", "Wan2.1-T2V-1.3B-Q4_K_M.gguf", 982_716_640,
                     "1e22a68152e6c4432524c61c78185efa35e6b305483ceb5fe238b2d51964cea7", role: "--diffusion-model"),
                part("Comfy-Org/Wan-2.1", "split_files/vae/wan_2.1_vae.safetensors", 253_815_318,
                     "2fc39d31359a4b0a64f55876d8ff7fa8d780956ae2cb13463b0223e15148976b", role: "--vae"),
                part("city96/umt5-xxl-encoder-gguf", "umt5-xxl-encoder-Q4_K_M.gguf", 3_655_145_312,
                     "17cf97a5bbbc60a646d6105b832b6f657ce904a8a1ad970e4b59df0c67584a40", role: "--t5xxl"),
            ]
        ),
    ]

    private static func part(_ repo: String, _ path: String, _ size: Int64, _ sha256: String, role: String?) -> LocalModelSpec {
        var spec = HuggingFaceHub.spec(repo: repo, file: HubFile(path: path, size: size, sha256: sha256), category: "image")
        spec.engine = .file
        spec.role = role
        return spec
    }

    private static func bundle(id: String, name: String, category: String, memory: Int, notes: String,
                               args: [String], parts: [LocalModelSpec]) -> LocalModelSpec {
        let bytes = parts.reduce(0) { $0 + $1.bytes }
        return LocalModelSpec(
            id: id, name: name, family: parts[0].family, sizeLabel: LocalModelCatalog.prettyBytes(bytes), context: 0,
            filename: parts[0].filename, url: parts[0].url, bytes: bytes, notes: notes, engine: .diffusion,
            repo: parts[0].repo, minMemoryGB: memory, category: category,
            components: parts, diffusionArgs: args
        )
    }

    /// Renders with the started model when it makes `kind`; nil leaves the request to providers.
    @MainActor
    public static func generate(kind: MediaKind, prompt: String, paths: SupportPaths) async throws -> (media: ChatMedia, model: String)? {
        guard let (runtime, spec) = active, spec.category == (kind == .video ? "video" : kind == .image ? "image" : "") else {
            return nil
        }
        if kind == .video {
            let data = try await runtime.renderVideo(spec, prompt: prompt)
            return (try MediaGenerationClient.save(data, kind: .video, paths: paths, prompt: prompt), spec.name)
        }
        let media = try await MediaGenerationClient.generate(
            kind: .image, prompt: prompt,
            configuration: AgentConfiguration(baseURL: baseURL, model: spec.id, provider: "Local"),
            provider: ProviderMediaSpec(model: spec.id, size: size(spec)), paths: paths
        )
        return (media, spec.name)
    }

    /// The request's size overrides the server's, so ask for the size the model was trained at.
    static func size(_ spec: LocalModelSpec) -> String? {
        let args = spec.diffusionArgs ?? []
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let width = value("-W"), let height = value("-H") else { return nil }
        return "\(width)x\(height)"
    }

    /// The files and generation flags `sd-server` / `sd-cli` start with.
    static func arguments(_ spec: LocalModelSpec, runtime: LocalRuntime) -> [String] {
        let parts = spec.components ?? [spec]
        return parts.flatMap { [$0.role ?? "-m", runtime.modelURL($0).path] } + (spec.diffusionArgs ?? [])
    }

    /// Frames as an H.264 MP4, the one video format every player here opens.
    static func encodeMP4(frames: [URL], fps: Int32, to output: URL) async throws {
        guard let first = frames.first.flatMap(image) else { throw RouterError(AppCopy.text("media.noOutput")) }
        let width = first.width, height = first.height
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RouterError(AppCopy.text("media.invalidOutput")) }
        writer.startSession(atSourceTime: .zero)
        for (index, frame) in frames.enumerated() {
            guard let picture = image(frame), let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
            context?.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RouterError(AppCopy.text("media.invalidOutput")) }
    }

    private static func image(_ url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

extension LocalRuntime {
    public var diffusionDirectory: URL { paths.runtime.appendingPathComponent("sdcpp-\(LocalDiffusion.tag)", isDirectory: true) }
    var diffusionServerURL: URL { diffusionDirectory.appendingPathComponent("sd-server") }
    var diffusionLogURL: URL { paths.runtime.appendingPathComponent("sd-server.log") }

    public func ensureDiffusion(progress: (@Sendable (FileDownloader.Progress) -> Void)? = nil) async throws {
        if runtimeInstalled(.diffusion) { return }
        let asset = LocalDiffusion.asset
        let archive = paths.runtime.appendingPathComponent("sdcpp.zip")
        try await FileDownloader.download(from: asset.url, to: archive, expected: asset.size, sha256: asset.sha256, progress: progress)
        let fm = FileManager.default
        try? fm.removeItem(at: diffusionDirectory)
        try fm.createDirectory(at: diffusionDirectory, withIntermediateDirectories: true)
        _ = try await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, diffusionDirectory.path])
        try? fm.removeItem(at: archive)
        guard runtimeInstalled(.diffusion) else { throw RouterError(AppCopy.text("localRuntime.serverMissingAfterUnpack")) }
    }

    /// Image models load once into a resident `sd-server`; video models only need
    /// their files, since each clip is one `sd-cli` run.
    public func startDiffusion(_ spec: LocalModelSpec) async throws {
        stopDiffusion()
        guard isInstalled(spec) else { throw RouterError(AppCopy.format("localRuntime.downloadFirst", spec.name)) }
        guard spec.category != "video" else { return }
        let process = Process()
        process.executableURL = diffusionServerURL
        process.currentDirectoryURL = diffusionDirectory
        process.arguments = ["-l", "127.0.0.1", "--listen-port", String(LocalDiffusion.port)]
            + LocalDiffusion.arguments(spec, runtime: self)
        FileManager.default.createFile(atPath: diffusionLogURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: diffusionLogURL)
        process.standardOutput = log
        process.standardError = log
        try process.run()
        diffusionProcess = process
        // Weights load before the port opens; FLUX can take a minute or two.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            guard process.isRunning else { break }
            if let url = URL(string: "\(LocalDiffusion.baseURL)/models"),
               let (_, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        stopDiffusion()
        let tail = (try? String(contentsOf: diffusionLogURL, encoding: .utf8))?.split(separator: "\n").suffix(6).joined(separator: "\n") ?? ""
        throw RouterError(AppCopy.format("local.serverNotReady", LocalDiffusion.port) + "\n" + tail)
    }

    public func stopDiffusion() {
        diffusionProcess?.terminate()
        diffusionProcess = nil
    }

    /// One clip: `sd-cli` writes PNG frames, which are encoded to MP4.
    public func renderVideo(_ spec: LocalModelSpec, prompt: String) async throws -> Data {
        let work = paths.runtime.appendingPathComponent("video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try await run(diffusionDirectory.appendingPathComponent("sd-cli"),
                          ["-M", "vid_gen", "-p", prompt, "-o", work.appendingPathComponent("frame_%03d.png").path]
                              + LocalDiffusion.arguments(spec, runtime: self))
        let frames = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let output = work.appendingPathComponent("clip.mp4")
        try await LocalDiffusion.encodeMP4(frames: frames, fps: LocalDiffusion.videoFPS, to: output)
        return try Data(contentsOf: output)
    }
}
