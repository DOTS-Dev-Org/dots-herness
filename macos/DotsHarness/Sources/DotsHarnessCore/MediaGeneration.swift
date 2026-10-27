// Copyright (c) 2026 DOTS
// Provider-backed image, video, speech, and music generation.

import CryptoKit
import Foundation
import PluginRuntime

public enum MediaKind: String, Codable, CaseIterable, Sendable, Equatable {
    case image
    case video
    case audio
    case music

    public var command: String {
        switch self {
        case .image: return "imagegen"
        case .video: return "videogen"
        case .audio: return "audiogen"
        case .music: return "musicgen"
        }
    }

    public var displayName: String {
        switch self {
        case .image: return AppCopy.text("media.image")
        case .video: return AppCopy.text("media.video")
        case .audio: return AppCopy.text("media.audio")
        case .music: return AppCopy.text("media.music")
        }
    }

    var defaultPath: String {
        switch self {
        case .image: return "/images/generations"
        case .video: return "/videos"
        case .audio: return "/audio/speech"
        // ponytail: no vendor-neutral music endpoint exists; a provider names its own in `media.music.path`.
        case .music: return "/audio/generations"
        }
    }

    var fileExtension: String {
        switch self {
        case .image: return "png"
        case .video: return "mp4"
        case .audio, .music: return "mp3"
        }
    }

    var mimeType: String {
        switch self {
        case .image: return "image/png"
        case .video: return "video/mp4"
        case .audio, .music: return "audio/mpeg"
        }
    }
}

public struct MediaRequest: Sendable, Equatable {
    public var kind: MediaKind
    public var prompt: String

    public init(kind: MediaKind, prompt: String) {
        self.kind = kind
        self.prompt = prompt
    }

    public static func parse(_ text: String) -> MediaRequest? {
        let parts = text.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
        guard let rawCommand = parts.first, rawCommand.first == "/" else { return nil }

        let command = rawCommand.dropFirst().lowercased()
        let kind: MediaKind?
        switch command {
        case "imagegen", "image", "img": kind = .image
        case "videogen", "video": kind = .video
        case "audiogen", "audio", "speech": kind = .audio
        case "musicgen", "music": kind = .music
        default: kind = nil
        }
        guard let kind else { return nil }
        return MediaRequest(
            kind: kind,
            prompt: parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public struct ChatMedia: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var kind: MediaKind
    public var path: String
    public var mimeType: String

    public init(
        id: String = UUID().uuidString,
        kind: MediaKind,
        path: String,
        mimeType: String
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.mimeType = mimeType
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Provider/tool content before it is materialized into the app's local
/// generated-media directory. Keeping this out of AgentMessage prevents raw
/// binary payloads from being persisted in the model transcript.
public struct MediaPayload: Sendable, Equatable {
    public var kind: MediaKind
    public var mimeType: String
    public var data: Data?
    public var url: URL?

    public init(kind: MediaKind, mimeType: String, data: Data? = nil, url: URL? = nil) {
        self.kind = kind
        self.mimeType = mimeType
        self.data = data
        self.url = url
    }
}

public enum MediaGenerationClient {
    public static func generate(
        kind: MediaKind,
        prompt: String,
        configuration: AgentConfiguration,
        provider: ProviderMediaSpec,
        paths: SupportPaths,
        session: URLSession = .shared,
        seconds: Int? = nil,
        stem: MusicStemRequest? = nil
    ) async throws -> ChatMedia {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NativeAgentError(AppCopy.text("media.promptMissing"))
        }
        guard !provider.model.isEmpty else {
            throw NativeAgentError(AppCopy.text("media.modelMissing"))
        }

        switch kind {
        case .image:
            return try await image(
                prompt: prompt,
                configuration: configuration,
                provider: provider,
                paths: paths,
                session: session
            )
        case .video:
            return try await video(
                prompt: prompt,
                configuration: configuration,
                provider: provider,
                paths: paths,
                session: session
            )
        case .audio:
            return try await audio(
                prompt: prompt,
                configuration: configuration,
                provider: provider,
                paths: paths,
                session: session
            )
        case .music:
            return try await music(
                prompt: prompt,
                seconds: seconds,
                stem: stem,
                configuration: configuration,
                provider: provider,
                paths: paths,
                session: session
            )
        }
    }

    private static func image(
        prompt: String,
        configuration: AgentConfiguration,
        provider: ProviderMediaSpec,
        paths: SupportPaths,
        session: URLSession
    ) async throws -> ChatMedia {
        var request = try request(
            url: endpoint(configuration: configuration, path: provider.path ?? MediaKind.image.defaultPath),
            configuration: configuration
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": provider.model,
            "prompt": prompt,
            "n": 1,
            "size": provider.size ?? "1024x1024",
        ])

        let (data, response) = try await session.data(for: request)
        try validate(data: data, response: response)
        let imageData = try await firstOutput(in: data, session: session)
        return try save(imageData, kind: .image, paths: paths, prompt: prompt)
    }

    /// `data[0]` of an OpenAI-style generation reply: inline base64, or a link to fetch.
    private static func firstOutput(in data: Data, session: URLSession) async throws -> Data {
        let value = try JSONCodec.parse(data)
        guard case .array(let items) = value["data"], let item = items.first else {
            throw NativeAgentError(AppCopy.text("media.noOutput"))
        }
        if let encoded = item["b64_json"]?.string {
            let raw = encoded.components(separatedBy: ",").last ?? encoded
            guard let decoded = Data(base64Encoded: raw) else {
                throw NativeAgentError(AppCopy.text("media.invalidOutput"))
            }
            return decoded
        }
        guard let rawURL = item["url"]?.string,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw NativeAgentError(AppCopy.text("media.noOutput"))
        }
        var download = URLRequest(url: url, timeoutInterval: 180)
        download.httpMethod = "GET"
        let (downloaded, downloadResponse) = try await session.data(for: download)
        try validate(data: downloaded, response: downloadResponse)
        return downloaded
    }

    private static func video(
        prompt: String,
        configuration: AgentConfiguration,
        provider: ProviderMediaSpec,
        paths: SupportPaths,
        session: URLSession
    ) async throws -> ChatMedia {
        let path = provider.path ?? MediaKind.video.defaultPath
        let boundary = "DotsHarness-\(UUID().uuidString)"
        var body = Data()
        MultipartFormData.appendField("model", value: provider.model, boundary: boundary, to: &body)
        MultipartFormData.appendField("prompt", value: prompt, boundary: boundary, to: &body)
        body.append(Data("--\(boundary)--\r\n".utf8))

        var createRequest = try request(
            url: endpoint(configuration: configuration, path: path),
            configuration: configuration
        )
        createRequest.httpMethod = "POST"
        createRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (createdData, createdResponse) = try await session.upload(for: createRequest, from: body)
        try validate(data: createdData, response: createdResponse)
        let created = try JSONCodec.parse(createdData)
        guard let videoID = created["id"]?.string, !videoID.isEmpty else {
            throw NativeAgentError(AppCopy.text("media.noOutput"))
        }

        let safeID = videoID.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        ) ?? videoID
        let jobURL = try endpoint(configuration: configuration, path: "\(path)/\(safeID)")

        // ponytail: poll for five minutes; add provider webhooks when long renders need a durable job queue.
        for attempt in 0..<150 {
            try Task.checkCancellation()
            var statusRequest = try request(url: jobURL, configuration: configuration)
            statusRequest.httpMethod = "GET"
            let (statusData, statusResponse) = try await session.data(for: statusRequest)
            try validate(data: statusData, response: statusResponse)
            let statusValue = try JSONCodec.parse(statusData)
            let status = statusValue["status"]?.string?.lowercased() ?? ""
            if status == "completed" || status == "succeeded" || status == "ready" {
                break
            }
            if status == "failed" || status == "cancelled" || status == "canceled" {
                let message = statusValue["error"]?["message"]?.string
                    ?? AppCopy.text("media.generationFailed")
                throw NativeAgentError(message)
            }
            if attempt == 149 {
                throw NativeAgentError(AppCopy.text("media.videoTimeout"), retryable: true)
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        var contentRequest = try request(
            url: endpoint(configuration: configuration, path: "\(path)/\(safeID)/content"),
            configuration: configuration
        )
        contentRequest.httpMethod = "GET"
        let (content, contentResponse) = try await session.data(for: contentRequest)
        try validate(data: content, response: contentResponse)
        return try save(content, kind: .video, paths: paths, prompt: prompt)
    }

    private static func audio(
        prompt: String,
        configuration: AgentConfiguration,
        provider: ProviderMediaSpec,
        paths: SupportPaths,
        session: URLSession
    ) async throws -> ChatMedia {
        var request = try request(
            url: endpoint(configuration: configuration, path: provider.path ?? MediaKind.audio.defaultPath),
            configuration: configuration
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": provider.model,
            "input": prompt,
            "voice": "marin",
            "instructions": "Speak naturally in the language of the input, with a warm conversational tone, natural pacing, varied intonation, and brief pauses. Avoid a robotic or announcer-like delivery.",
            "response_format": "mp3",
        ])

        let (data, response) = try await session.data(for: request)
        try validate(data: data, response: response)
        return try save(data, kind: .audio, paths: paths, prompt: prompt)
    }

    /// Text to music. The reply is either the audio itself or the JSON envelope image generation uses.
    private static func music(
        prompt: String,
        seconds: Int?,
        stem: MusicStemRequest?,
        configuration: AgentConfiguration,
        provider: ProviderMediaSpec,
        paths: SupportPaths,
        session: URLSession
    ) async throws -> ChatMedia {
        let elevenLabs = provider.format == MusicEndpoint.Format.elevenLabs.rawValue
        var request = try request(
            url: endpoint(
                configuration: configuration,
                path: provider.path ?? (elevenLabs ? "/music" : MediaKind.music.defaultPath)
            ),
            configuration: configuration
        )
        request.httpMethod = "POST"
        // A model on this machine can take several times the track's length to render it.
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/*, application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any]
        if elevenLabs {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(configuration.apiKey, forHTTPHeaderField: "xi-api-key")
            body = ["prompt": prompt, "model_id": provider.model]
            if let seconds { body["music_length_ms"] = min(max(seconds * 1000, 3000), 600_000) }
            if let stem, stem.lyrics == nil { body["force_instrumental"] = true }
        } else {
            body = ["model": provider.model, "prompt": prompt]
            if let seconds { body["duration"] = seconds }
            if let stem {
                body["instrument"] = stem.instrument
                body["bpm"] = stem.bpm
                body["key"] = stem.key
                if let lyrics = stem.lyrics { body["lyrics"] = lyrics }
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validate(data: data, response: response)
        let isJSON = response.mimeType?.lowercased().contains("json") == true
        return try save(
            isJSON ? try await firstOutput(in: data, session: session) : data,
            kind: .music, paths: paths, prompt: prompt
        )
    }

    private static func endpoint(configuration: AgentConfiguration, path: String) throws -> URL {
        guard var components = URLComponents(string: configuration.baseURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw NativeAgentError(AppCopy.text("agent.invalidEndpoint"))
        }
        let base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [base, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw NativeAgentError(AppCopy.text("agent.invalidEndpoint")) }
        return url
    }

    private static func request(url: URL, configuration: AgentConfiguration) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            if configuration.api == RouterAPIKind.anthropic.rawValue && !configuration.isOAuth {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private static func validate(data: Data, response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let value = try? JSONCodec.parse(data)
            let message = value?["error"]?["message"]?.string
                ?? value?["message"]?.string
                ?? value?["detail"]?["message"]?.string
                ?? value?["detail"]?.string
                ?? AppCopy.format("agent.requestFailed", status)
            throw NativeAgentError(message, statusCode: status, retryable: status == 408 || status == 429 || (500..<600).contains(status))
        }
    }

    static func save(_ data: Data, kind: MediaKind, paths: SupportPaths, prompt: String? = nil) throws -> ChatMedia {
        try save(data, kind: kind, mimeType: kind.mimeType, paths: paths, prompt: prompt)
    }

    static let maxSavedBytes = 200 * 1024 * 1024

    /// Fixed `generated-media` directory only; the name is the SHA-256 of the bytes
    /// (no collisions, identical content dedupes) and, for images, the extension
    /// comes from magic bytes rather than the provider's Content-Type. Every saved
    /// file is filed in the library; `prompt` becomes its title there.
    static func save(
        _ data: Data, kind: MediaKind, mimeType: String, paths: SupportPaths, prompt: String? = nil
    ) throws -> ChatMedia {
        guard !data.isEmpty, data.count <= maxSavedBytes else { throw NativeAgentError(AppCopy.text("media.invalidOutput")) }
        var ext = kind.fileExtension
        var mime = mimeType
        if kind == .image {
            guard let sniffed = sniffImage(data) else { throw NativeAgentError(AppCopy.text("media.invalidOutput")) }
            (ext, mime) = sniffed
        } else if kind == .music, let sniffed = sniffAudio(data) {
            (ext, mime) = sniffed
        }
        let directory = paths.root.appendingPathComponent("generated-media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(name).\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        if let libraryKind = MediaLibraryItem.Kind(rawValue: kind.rawValue) {
            MediaLibrary.record(url, kind: libraryKind, prompt: prompt, root: paths.root)
        }
        return ChatMedia(kind: kind, path: url.path, mimeType: mime)
    }

    /// Music servers answer in whatever container they render to; the default stays mp3.
    private static func sniffAudio(_ d: Data) -> (String, String)? {
        let b = [UInt8](d.prefix(4))
        if b == [0x52, 0x49, 0x46, 0x46] { return ("wav", "audio/wav") }
        if b == [0x66, 0x4C, 0x61, 0x43] { return ("flac", "audio/flac") }
        if b == [0x4F, 0x67, 0x67, 0x53] { return ("ogg", "audio/ogg") }
        return nil
    }

    private static func sniffImage(_ d: Data) -> (String, String)? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("png", "image/png") }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return ("jpg", "image/jpeg") }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return ("gif", "image/gif") }
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return ("webp", "image/webp") }
        return nil
    }

    public static func materialize(
        _ payload: MediaPayload,
        paths: SupportPaths,
        session: URLSession = .shared
    ) async throws -> ChatMedia {
        if let data = payload.data {
            return try save(data, kind: payload.kind, mimeType: payload.mimeType, paths: paths)
        }
        guard let url = payload.url,
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw NativeAgentError(AppCopy.text("media.invalidOutput"))
        }
        let request = URLRequest(url: url, timeoutInterval: 180)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NativeAgentError(AppCopy.format("agent.requestFailed", status))
        }
        return try save(data, kind: payload.kind, mimeType: payload.mimeType, paths: paths)
    }
}
