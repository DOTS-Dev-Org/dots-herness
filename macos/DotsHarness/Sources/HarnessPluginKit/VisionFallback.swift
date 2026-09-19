// Copyright (c) 2026 DOTS
// In-process vision fallback contract for the macOS host and plugins.

import Foundation

public enum VisionFallbackState: String, Sendable, Equatable {
    case unavailable
    case modelMissing
    case downloading
    case preparing
    case ready
    case failed
}

public struct VisionImageInput: Sendable, Equatable {
    public var filePath: String
    public var name: String
    public var mimeType: String

    public init(filePath: String, name: String, mimeType: String) {
        self.filePath = filePath
        self.name = name
        self.mimeType = mimeType
    }
}

public struct PluginSupportPaths: Sendable, Equatable {
    public var root: URL
    public var plugins: URL
    public var models: URL
    public var runtime: URL

    public init(root: URL, plugins: URL, models: URL, runtime: URL) {
        self.root = root
        self.plugins = plugins
        self.models = models
        self.runtime = runtime
    }
}

public enum VisionFallbackDefaults {
    public static let pluginID = "dots.vision-fallback"
    public static let serviceName = "vision.fallback"
    public static let installerServiceName = "vision.installer"
    public static let modelBytes: Int64 = 279_000_000
}

@MainActor
public protocol VisionFallbackService: AnyObject {
    var state: VisionFallbackState { get }
    var modelBytes: Int64 { get }
    var error: String? { get }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    func describe(images: [VisionImageInput], instruction: String) async throws -> String
    func deleteModel() throws
    func shutdown()
}

@MainActor
public protocol VisionFallbackInstaller: AnyObject {
    func install() async throws -> (any VisionFallbackService)?
}

public enum VisionProviderCapability {
    private static let unsupportedStatusCodes: Set<Int> = [400, 404, 405, 415, 422]
    private static let positiveTerms = [
        "image", "multimodal", "image_url", "image input", "image inputs", "image modality", "vision"
    ]
    private static let unsupportedTerms = [
        "does not support", "doesn't support", "not supported", "unsupported",
        "not available", "unavailable", "not implemented", "cannot process",
        "can't process", "disabled"
    ]
    private static let invalidImageTerms = [
        "invalid image", "malformed image", "decode image", "image decode", "image decoding failed",
        "failed to decode image", "corrupt image", "unsafe image", "unsupported image format"
    ]

    public static func isImageInputUnsupported(message: String, statusCode: Int?) -> Bool {
        guard let statusCode, unsupportedStatusCodes.contains(statusCode) else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let capability = positiveTerms.contains(where: text.contains)
        let unsupported = unsupportedTerms.contains(where: text.contains)
            || text.contains("no image support")
            || text.contains("not multimodal")
            || text.contains("no vision support")
            || text.contains("image support unavailable")
        let missingModel = text.contains("model")
            && (text.contains("not found") || text.contains("not available")
                || text.contains("unavailable") || text.contains("does not exist"))
        return capability && unsupported && !missingModel
            && !invalidImageTerms.contains(where: text.contains)
    }
}
