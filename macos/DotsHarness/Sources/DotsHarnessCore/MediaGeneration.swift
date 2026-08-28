// Copyright (c) 2026 DOTS
// Provider-backed image, video, and speech generation.

import Foundation
import PluginRuntime

public enum MediaKind: String, Codable, CaseIterable, Sendable, Equatable {
    case image
    case video
    case audio

    public var command: String {
        switch self {
        case .image: return "imagegen"
        case .video: return "videogen"
        case .audio: return "audiogen"
        }
    }

    public var displayName: String {
        switch self {
        case .image: return AppCopy.text("media.image")
        case .video: return AppCopy.text("media.video")
        case .audio: return AppCopy.text("media.audio")
        }
    }

    var defaultPath: String {
        switch self {
        case .image: return "/images/generations"
        case .video: return "/videos"
        case .audio: return "/audio/speech"
        }
    }

    var fileExtension: String {
        switch self {
        case .image: return "png"
        case .video: return "mp4"
        case .audio: return "mp3"
        }
    }

    var mimeType: String {
        switch self {
        case .image: return "image/png"
        case .video: return "video/mp4"
        case .audio: return "audio/mpeg"
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

public enum MediaGenerationClient {
    public static func generate(
        kind: MediaKind,
        prompt: String,
        configuration: AgentConfiguration,
        provider: ProviderMediaSpec,
        paths: SupportPaths,
        session: URLSession = .shared
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
            "size": "1024x1024",
        ])

        let (data, response) = try await session.data(for: request)
        try validate(data: data, response: response)
        let value = try JSONCodec.parse(data)
        guard case .array(let items) = value["data"], let item = items.first else {
            throw NativeAgentError(AppCopy.text("media.noOutput"))
        }

        let imageData: Data
        if let encoded = item["b64_json"]?.string {
            let raw = encoded.components(separatedBy: ",").last ?? encoded
            guard let decoded = Data(base64Encoded: raw) else {
                throw NativeAgentError(AppCopy.text("media.invalidOutput"))
            }
            imageData = decoded
        } else if let rawURL = item["url"]?.string,
                  let url = URL(string: rawURL),
                  ["http", "https"].contains(url.scheme?.lowercased()) {
            var download = URLRequest(url: url, timeoutInterval: 180)
            download.httpMethod = "GET"
            let (downloaded, downloadResponse) = try await session.data(for: download)
            try validate(data: downloaded, response: downloadResponse)
            imageData = downloaded
        } else {
            throw NativeAgentError(AppCopy.text("media.noOutput"))
        }

        return try save(imageData, kind: .image, paths: paths)
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
        appendField("model", value: provider.model, boundary: boundary, to: &body)
        appendField("prompt", value: prompt, boundary: boundary, to: &body)
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
        return try save(content, kind: .video, paths: paths)
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
        return try save(data, kind: .audio, paths: paths)
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
                ?? AppCopy.format("agent.requestFailed", status)
            throw NativeAgentError(message, statusCode: status, retryable: status == 408 || status == 429 || (500..<600).contains(status))
        }
    }

    static func save(_ data: Data, kind: MediaKind, paths: SupportPaths) throws -> ChatMedia {
        let directory = paths.root.appendingPathComponent("generated-media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory
            .appendingPathComponent("\(UUID().uuidString).\(kind.fileExtension)")
        try data.write(to: url, options: .atomic)
        return ChatMedia(kind: kind, path: url.path, mimeType: kind.mimeType)
    }

    private static func appendField(_ name: String, value: String, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }
}
