// Copyright (c) 2026 DOTS
// In-process SmolVLM/libmtmd plugin for the removable Vision fallback.

import Foundation
import CryptoKit
import HarnessPluginKit

#if os(macOS)
import Darwin
#endif

public final class VisionPlugin: HarnessPlugin {
    public static let manifest = PluginManifest(
        id: VisionFallbackDefaults.pluginID,
        name: "Vision fallback",
        version: "1.0.0",
        plane: .host,
        inject: ["support.paths"],
        description: "Describes images locally with SmolVLM-256M-Instruct and libmtmd.",
        library: "libVisionPlugin.dylib"
    )

    public init() {}

    public func apply(_ ctx: PluginContext) throws {
        guard let directory = ctx.pluginDirectory?.standardizedFileURL,
              let paths = ctx.get("support.paths") as? PluginSupportPaths else {
            throw PluginError.missingService("support.paths")
        }
        let service = try SmolVlmVisionService(pluginDirectory: directory, paths: paths)
        ctx.provide(VisionFallbackDefaults.serviceName, service)
        ctx.effect { service.shutdown() }
    }
}

@MainActor
private final class SmolVlmVisionService: VisionFallbackService {
    private let pluginDirectory: URL
    private let modelDirectory: URL
    private let manifest: VisionModelManifest
    private var runtime: VisionNativeRuntime?

    private(set) var state: VisionFallbackState
    private(set) var error: String?

    var modelBytes: Int64 { max(manifest.files.reduce(0) { $0 + $1.size }, VisionFallbackDefaults.modelBytes) }

    init(pluginDirectory: URL, paths: PluginSupportPaths) throws {
        let modelDirectory = paths.models
            .appendingPathComponent("vision", isDirectory: true)
            .appendingPathComponent("smolvlm-256m-q8", isDirectory: true)
        let manifest = try VisionModelManifest.load(
            from: pluginDirectory.appendingPathComponent("assets/vision-models.json")
        )
        self.pluginDirectory = pluginDirectory
        self.modelDirectory = modelDirectory
        self.manifest = manifest
        state = manifest.files.allSatisfy { file in
            let url = modelDirectory.appendingPathComponent(file.name)
            return Self.validFile(url, file: file)
        } ? .preparing : .modelMissing
    }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        if state == .ready, runtime != nil { return }
        do {
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            state = .downloading
            error = nil
            let fileCount = manifest.files.count
            for (index, file) in manifest.files.enumerated() {
                let url = try modelURL(for: file)
                let remote = try remoteURL(for: file)
                try await VisionModelDownloader.download(
                    from: remote,
                    to: url,
                    expected: file.size,
                    sha256: file.sha256,
                    progress: { value in
                        progress?(min(0.8, (Double(index) + value.fraction) / Double(fileCount) * 0.8))
                    }
                )
            }
            state = .preparing
            progress?(0.82)
            runtime?.shutdown()
            runtime = nil
            runtime = try VisionNativeRuntime(
                library: safePluginURL(manifest.runtimeLibrary),
                model: try modelURL(for: manifest.textModel),
                projector: try modelURL(for: manifest.projector)
            )
            progress?(1)
            state = .ready
        } catch is CancellationError {
            state = .modelMissing
            throw CancellationError()
        } catch {
            state = .failed
            self.error = error.localizedDescription
            throw error
        }
    }

    func describe(images: [VisionImageInput], instruction: String) async throws -> String {
        guard !images.isEmpty else { throw VisionPluginError.noImages }
        guard state == .ready, let runtime else { throw VisionPluginError.notReady }
        var output: [String] = []
        for image in images {
            guard FileManager.default.fileExists(atPath: image.filePath) else {
                throw VisionPluginError.imageMissing(image.filePath)
            }
            let text = try runtime.describe(image: image.filePath, instruction: instruction).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { output.append(text) }
        }
        return output.joined(separator: "\n\n")
    }

    func deleteModel() throws {
        runtime?.shutdown()
        runtime = nil
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
        state = .modelMissing
        error = nil
    }

    func shutdown() {
        runtime?.shutdown()
        runtime = nil
        state = .unavailable
    }

    private func modelURL(for file: VisionModelFile) throws -> URL {
        try safeModelURL(file.name)
    }

    private func modelURL(for name: String) throws -> URL {
        try safeModelURL(name)
    }

    private func safeModelURL(_ name: String) throws -> URL {
        let url = modelDirectory.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(modelDirectory.standardizedFileURL.path + "/") else {
            throw VisionPluginError.unsafePath(name)
        }
        return url
    }

    private func safePluginURL(_ name: String) throws -> URL {
        let url = pluginDirectory.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(pluginDirectory.path + "/") else {
            throw VisionPluginError.unsafePath(name)
        }
        return url
    }

    private func remoteURL(for file: VisionModelFile) throws -> URL {
        guard let url = URL(string: "https://huggingface.co/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/\(manifest.revision)/\(file.name)?download=true") else {
            throw VisionPluginError.invalidManifest
        }
        return url
    }

    private static func validFile(_ url: URL, file: VisionModelFile) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size == file.size,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let digest = SHA256.hex(data)
        return digest.caseInsensitiveCompare(file.sha256) == .orderedSame
    }
}

private struct VisionModelManifest: Decodable {
    var revision: String
    var runtimeLibrary: String
    var textModel: String
    var projector: String
    var files: [VisionModelFile]

    static func load(from url: URL) throws -> VisionModelManifest {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !manifest.revision.isEmpty,
              manifest.revision.count == 40,
              manifest.revision.allSatisfy(\.isHexDigit),
              !manifest.runtimeLibrary.isEmpty,
              !manifest.textModel.isEmpty,
              !manifest.projector.isEmpty,
              !manifest.files.isEmpty,
              manifest.files.allSatisfy({ file in
                  file.size > 0
                      && file.name.isSafeRelativePath
                      && file.sha256.count == 64
                      && file.sha256.allSatisfy(\.isHexDigit)
              }),
              manifest.files.contains(where: { $0.name == manifest.textModel }),
              manifest.files.contains(where: { $0.name == manifest.projector }) else {
            throw VisionPluginError.invalidManifest
        }
        return manifest
    }
}

private struct VisionModelFile: Decodable {
    var name: String
    var size: Int64
    var sha256: String
}

private extension String {
    var isSafeRelativePath: Bool {
        !isEmpty && !contains("/") && !contains("\\") && self != "." && self != ".."
    }
}

private enum VisionPluginError: LocalizedError {
    case invalidManifest
    case unsafePath(String)
    case noImages
    case notReady
    case imageMissing(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Vision model manifest is invalid."
        case .unsafePath(let path): return "Unsafe Vision path: \(path)"
        case .noImages: return "At least one image is required."
        case .notReady: return "Vision model is not ready."
        case .imageMissing(let path): return "Image file was not found: \(path)"
        case .runtime(let message): return message
        }
    }
}

private final class VisionNativeRuntime: @unchecked Sendable {
    private typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, Int32) -> UnsafeMutableRawPointer?
    private typealias Describe = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    private typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias LastError = @convention(c) () -> UnsafePointer<CChar>?

    private let library: UnsafeMutableRawPointer
    private let create: Create
    private let describeFunction: Describe
    private let freeString: FreeString
    private let destroy: Destroy
    private let lastError: LastError
    private var context: UnsafeMutableRawPointer?

    init(library url: URL, model: URL, projector: URL) throws {
        guard let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw VisionPluginError.runtime(String(cString: dlerror()))
        }
        self.library = library
        do {
            create = try Self.symbol("dots_vision_create", from: library)
            describeFunction = try Self.symbol("dots_vision_describe", from: library)
            freeString = try Self.symbol("dots_vision_free_string", from: library)
            destroy = try Self.symbol("dots_vision_destroy", from: library)
            lastError = try Self.symbol("dots_vision_last_error", from: library)
            context = model.path.withCString { modelPath in
                projector.path.withCString { projectorPath in
                    create(modelPath, projectorPath, Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
                }
            }
            guard context != nil else { throw VisionPluginError.runtime(errorMessage("Vision runtime initialization failed.")) }
        } catch {
            dlclose(library)
            throw error
        }
    }

    func describe(image: String, instruction: String) throws -> String {
        guard let context else { throw VisionPluginError.runtime("Vision runtime is closed.") }
        var result: UnsafeMutablePointer<CChar>?
        let code = image.withCString { imagePath in
            instruction.withCString { prompt in
                describeFunction(context, imagePath, prompt, &result)
            }
        }
        guard code == 0 else { throw VisionPluginError.runtime(errorMessage("Vision runtime failed.")) }
        defer { if let result { freeString(result) } }
        return result.map { String(cString: $0) } ?? ""
    }

    func shutdown() {
        guard let context else { return }
        destroy(context)
        self.context = nil
        dlclose(library)
    }

    private func errorMessage(_ fallback: String) -> String {
        guard let pointer = lastError() else { return fallback }
        let value = String(cString: pointer)
        return value.isEmpty ? fallback : value
    }

    private static func symbol<T>(_ name: String, from library: UnsafeMutableRawPointer) throws -> T {
        guard let raw = dlsym(library, name) else { throw VisionPluginError.runtime("Missing Vision runtime symbol: \(name)") }
        return unsafeBitCast(raw, to: T.self)
    }
}

private enum SHA256 {
    static func hex(_ data: Data) -> String {
        data.withUnsafeBytes { bytes in
            CryptoKit.SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }
}

// C ABI expected by PluginDylib.load().
@_cdecl("harness_plugin_abi_version")
public func harness_plugin_abi_version() -> UnsafePointer<CChar> { VisionPluginCString.abi }

@_cdecl("harness_plugin_id")
public func harness_plugin_id() -> UnsafePointer<CChar> { VisionPluginCString.id }

@_cdecl("harness_plugin_make")
public func harness_plugin_make() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(VisionPlugin()).toOpaque()
}

private enum VisionPluginCString {
    nonisolated(unsafe) static let abi = UnsafePointer(strdup("1.0.0")!)
    nonisolated(unsafe) static let id = UnsafePointer(strdup(VisionFallbackDefaults.pluginID)!)
}
