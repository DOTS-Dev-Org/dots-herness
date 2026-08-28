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

public enum VisionProviderCapability {
    private static let unsupportedStatusCodes: Set<Int> = [400, 404, 405, 415, 422]
    private static let positiveTerms = [
        "does not support", "doesn't support", "not supported", "unsupported",
        "multimodal", "image_url", "image input", "image inputs", "image modality", "vision"
    ]
    private static let invalidImageTerms = [
        "invalid image", "malformed image", "decode image", "image decode", "corrupt image", "unsafe image"
    ]

    public static func isImageInputUnsupported(message: String, statusCode: Int?) -> Bool {
        guard let statusCode, unsupportedStatusCodes.contains(statusCode) else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return positiveTerms.contains(where: text.contains)
            && !invalidImageTerms.contains(where: text.contains)
    }
}
