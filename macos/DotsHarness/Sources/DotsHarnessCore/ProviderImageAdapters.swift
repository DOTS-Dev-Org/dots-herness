import Foundation
import HarnessPluginKit

public struct ProviderImageGeneration: Sendable, Equatable {
    public var output: ProviderImageOutput
    public var provider: String
    public var model: String
    public var fallbackFrom: String?

    public init(output: ProviderImageOutput, provider: String, model: String, fallbackFrom: String? = nil) {
        self.output = output
        self.provider = provider
        self.model = model
        self.fallbackFrom = fallbackFrom
    }
}

public enum ProviderImageGenerationError: Error, LocalizedError, Sendable, Equatable {
    case unsupported(String)
    case failed(ProviderImageFailure)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .failed(let failure): return failure.message
        }
    }
}

enum ProviderImageAdapterSupport {
    static func endpoint(baseURL: String, path: String) -> URL? {
        guard var components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        let base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [base, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func data(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    static func decode(_ encoded: String) -> Data? {
        let raw = encoded.components(separatedBy: ",").last ?? encoded
        return Data(base64Encoded: raw, options: .ignoreUnknownCharacters)
    }

    static func failure(data: Data, status: Int) -> ProviderImageResult {
        let message = message(from: data, status: status)
        let lower = message.lowercased()
        if status == 401 || (status == 403 && !isSafety(lower)) {
            return .failed(ProviderImageFailure(kind: .auth, message: message))
        }
        if status == 429 { return .failed(ProviderImageFailure(kind: .rateLimit, message: message)) }
        if status >= 500 { return .failed(ProviderImageFailure(kind: .server, message: message)) }
        if isSafety(lower) { return .failed(ProviderImageFailure(kind: .safety, message: message)) }
        if status == 404 || status == 405 || isCapability(lower) {
            return .unsupported(message)
        }
        return .failed(ProviderImageFailure(kind: .other, message: message))
    }

    static func invalidOutput(_ message: String) -> ProviderImageResult {
        .failed(ProviderImageFailure(kind: .invalidOutput, message: message))
    }

    static func message(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["error"].flatMap({ $0 as? [String: Any] })?["message"] as? String, !message.isEmpty { return message }
            if let message = object["message"] as? String, !message.isEmpty { return message }
            if let statusText = object["status"] as? String, !statusText.isEmpty { return statusText }
        }
        return "Image provider returned HTTP \(status)."
    }

    static func isSafety(_ value: String) -> Bool {
        ["safety", "policy", "content policy", "blocked", "prohibited", "responsible"].contains { value.contains($0) }
    }

    static func isCapability(_ value: String) -> Bool {
        [
            "image_generation", "image generation", "responsemodalities", "response modalities",
            "inline data", "unsupported", "not supported", "does not support", "unknown tool",
            "invalid tool", "not available",
        ].contains { value.contains($0) }
    }

    static func imageBase64FromOpenAI(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return openAIResult(in: object)
        }
        var result: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]",
                  let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { continue }
            guard let object = event as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "response.output_item.done": result = openAIResult(in: object["item"] ?? object) ?? result
            case "response.completed", "response.incomplete": result = openAIResult(in: object["response"] ?? object) ?? result
            case "response.image_generation_call.completed":
                result = object["result"] as? String
                    ?? (object["image_generation_call"] as? [String: Any])?["result"] as? String
                    ?? result
            default: break
            }
        }
        return result
    }

    private static func openAIResult(in value: Any) -> String? {
        guard let object = value as? [String: Any] else {
            if let values = value as? [Any] { return values.lazy.compactMap(openAIResult).first }
            return nil
        }
        if object["type"] as? String == "image_generation_call" { return object["result"] as? String }
        if let nested = object["response"], let result = openAIResult(in: nested) { return result }
        if let nested = object["item"], let result = openAIResult(in: nested) { return result }
        if let nested = object["image_generation_call"], let result = openAIResult(in: nested) { return result }
        if let nested = object["output"], let result = openAIResult(in: nested) { return result }
        return nil
    }

    static func imageFromGemini(_ data: Data) -> ProviderImageOutput? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = root["response"] as? [String: Any] ?? root
        guard let candidates = payload["candidates"] as? [[String: Any]] else { return nil }
        for candidate in candidates {
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            for part in parts {
                let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
                guard let inline,
                      let encoded = inline["data"] as? String,
                      let image = decode(encoded) else { continue }
                return ProviderImageOutput(data: image, mimeType: inline["mimeType"] as? String ?? inline["mime_type"] as? String ?? "image/png")
            }
        }
        return nil
    }
}

final class OpenAIResponsesImageAdapter: ProviderImageAdapter {
    let id = "openai.responses.image"

    func matches(_ route: ProviderImageRoute) -> Bool {
        route.api == RouterAPIKind.chatGPT.rawValue || route.providerID.lowercased() == "openai"
    }

    func prepareImageRequest(prompt: String, model: String, route: ProviderImageRoute) throws -> ProviderImageRequest {
        guard let url = ProviderImageAdapterSupport.endpoint(baseURL: route.baseURL, path: "responses"),
              let body = ProviderImageAdapterSupport.data([
                  "model": model,
                  "instructions": route.providerID == "gpt" ? CodexInstructions.default : "You are a helpful assistant.",
                  "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
                  "tools": [["type": "image_generation"]],
                  "store": false,
                  "stream": true,
              ]) else { throw NativeAgentError(AppCopy.text("agent.invalidEndpoint")) }
        return ProviderImageRequest(
            url: url,
            body: body,
            headers: ["Content-Type": "application/json", "Accept": "text/event-stream"],
            authentication: .bearer
        )
    }

    func parseImageResponse(data: Data, status: Int, headers: [String: String]) -> ProviderImageResult {
        guard (200..<300).contains(status) else { return ProviderImageAdapterSupport.failure(data: data, status: status) }
        guard let encoded = ProviderImageAdapterSupport.imageBase64FromOpenAI(data),
              let image = ProviderImageAdapterSupport.decode(encoded) else {
            return ProviderImageAdapterSupport.invalidOutput(AppCopy.text("media.noOutput"))
        }
        return .generated(ProviderImageOutput(data: image, mimeType: "image/png"))
    }
}

final class GeminiNativeImageAdapter: ProviderImageAdapter {
    let id = "gemini.native.image"

    func matches(_ route: ProviderImageRoute) -> Bool {
        route.providerID.lowercased() == "gemini"
    }

    func prepareImageRequest(prompt: String, model: String, route: ProviderImageRoute) throws -> ProviderImageRequest {
        guard var components = URLComponents(string: route.baseURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme), components.host != nil else {
            throw NativeAgentError(AppCopy.text("agent.invalidEndpoint"))
        }
        var base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.hasSuffix("/openai") { base.removeLast("/openai".count) }
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? model
        components.path = "/" + [base, "models/\(encodedModel):generateContent"].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url,
              let body = ProviderImageAdapterSupport.data([
                  "contents": [["role": "user", "parts": [["text": prompt]]]],
                  "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
              ]) else { throw NativeAgentError(AppCopy.text("agent.invalidEndpoint")) }
        return ProviderImageRequest(
            url: url,
            body: body,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            authentication: .rawHeader("x-goog-api-key")
        )
    }

    func parseImageResponse(data: Data, status: Int, headers: [String: String]) -> ProviderImageResult {
        guard (200..<300).contains(status) else { return ProviderImageAdapterSupport.failure(data: data, status: status) }
        guard let output = ProviderImageAdapterSupport.imageFromGemini(data) else {
            return ProviderImageAdapterSupport.invalidOutput(AppCopy.text("media.noOutput"))
        }
        return .generated(output)
    }
}

final class DirectImageAPIAdapter: ProviderImageAdapter {
    let id = "openai.images.fallback"
    let isFallbackOnly = true

    func matches(_ route: ProviderImageRoute) -> Bool {
        route.providerID.lowercased() == "openai"
    }

    func prepareImageRequest(prompt: String, model: String, route: ProviderImageRoute) throws -> ProviderImageRequest {
        guard let url = ProviderImageAdapterSupport.endpoint(baseURL: route.baseURL, path: "images/generations"),
              let body = ProviderImageAdapterSupport.data([
                  "model": "gpt-image-1.5",
                  "prompt": prompt,
                  "n": 1,
                  "size": "1024x1024",
              ]) else { throw NativeAgentError(AppCopy.text("agent.invalidEndpoint")) }
        return ProviderImageRequest(
            url: url,
            body: body,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            authentication: .bearer
        )
    }

    func parseImageResponse(data: Data, status: Int, headers: [String: String]) -> ProviderImageResult {
        guard (200..<300).contains(status) else { return ProviderImageAdapterSupport.failure(data: data, status: status) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = (root["data"] as? [[String: Any]])?.first,
              let encoded = item["b64_json"] as? String,
              let image = ProviderImageAdapterSupport.decode(encoded) else {
            return ProviderImageAdapterSupport.invalidOutput(AppCopy.text("media.noOutput"))
        }
        return .generated(ProviderImageOutput(data: image, mimeType: "image/png"))
    }
}

@MainActor
enum BuiltInProviderImageAdapters {
    static func register(on registry: ProviderImageAdapterRegistry) {
        try? registry.register(OpenAIResponsesImageAdapter(), owner: "host", trust: .system)
        try? registry.register(GeminiNativeImageAdapter(), owner: "host", trust: .system)
        try? registry.register(DirectImageAPIAdapter(), owner: "host", trust: .system)
    }
}
