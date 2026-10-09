// Copyright (c) 2026 DOTS
// Provider-native media extraction and error classification.

import Foundation
import HarnessPluginKit
import PluginRuntime

extension NativeAgentClient {
    /// Extracts only provider-native media blocks. Plain markdown/URLs in text
    /// are intentionally ignored so a model cannot cause an unsolicited
    /// download merely by mentioning an image URL.
    static func mediaPayloads(from value: JSONValue) -> [MediaPayload] {
        var payloads: [MediaPayload] = []
        if let payload = mediaPayload(from: value) {
            payloads.append(payload)
        }

        switch value {
        case .array(let values):
            for value in values { payloads.append(contentsOf: mediaPayloads(from: value)) }
        case .object:
            for key in ["output", "content", "parts", "candidates", "response"] {
                if let nested = value[key] {
                    payloads.append(contentsOf: mediaPayloads(from: nested))
                }
            }
        case .null, .bool, .number, .string:
            break
        }
        return payloads
    }

    private static func mediaPayload(from value: JSONValue) -> MediaPayload? {
        let type = value["type"]?.string?.lowercased() ?? ""
        let nested = value["image_url"] ?? value["audio_url"] ?? value["video_url"] ?? value["source"] ?? value["inlineData"] ?? value["fileData"] ?? .null
        let nestedObject = nested.object
        let mimeType = (
            value["mimeType"]?.string
                ?? value["mime_type"]?.string
                ?? value["media_type"]?.string
                ?? nestedObject?["mimeType"]?.string
                ?? nestedObject?["media_type"]?.string
                ?? inferredMIMEType(for: type)
        )?.lowercased()

        guard let mimeType, let kind = mediaKind(mimeType: mimeType, type: type) else { return nil }

        let rawBase64 = value["b64_json"]?.string
            ?? value["blob"]?.string
            ?? value["result"]?.string
            ?? nestedObject?["data"]?.string
            ?? (nested.string.flatMap { type.contains("image") || type.contains("audio") || type.contains("video") ? $0 : nil })
        if let rawBase64 {
            let encoded = rawBase64.components(separatedBy: ",").last ?? rawBase64
            if let data = Data(base64Encoded: encoded), !data.isEmpty {
                return MediaPayload(kind: kind, mimeType: mimeType, data: data)
            }
        }

        let rawURL = value["url"]?.string
            ?? value["file_url"]?.string
            ?? value["uri"]?.string
            ?? nestedObject?["url"]?.string
            ?? nestedObject?["fileUri"]?.string
        if let rawURL, let url = URL(string: rawURL),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            return MediaPayload(kind: kind, mimeType: mimeType, url: url)
        }
        return nil
    }

    private static func mediaKind(mimeType: String, type: String) -> MediaKind? {
        if mimeType.hasPrefix("image/") || type.contains("image") { return .image }
        if mimeType.hasPrefix("video/") || type.contains("video") { return .video }
        if mimeType.hasPrefix("audio/") || type.contains("audio") { return .audio }
        return nil
    }

    private static func inferredMIMEType(for type: String) -> String? {
        if type.contains("image") { return "image/png" }
        if type.contains("video") { return "video/mp4" }
        if type.contains("audio") { return "audio/mpeg" }
        return nil
    }

    static func errorMessage(from value: JSONValue, status: Int) -> String {
        if let message = value["error"]?["message"]?.string ?? value["message"]?.string,
           !message.isEmpty {
            return message
        }
        return AppCopy.format("agent.requestFailed", status)
    }

    static func limitKind(from value: JSONValue, status: Int) -> String? {
        if status == 429 { return "rate" }
        if status == 402 { return "balance" }
        let message = [
            value["error"]?["message"]?.string,
            value["error"]?["type"]?.string,
            value["error"]?["code"]?.string,
            value["response"]?["error"]?["message"]?.string,
            value["response"]?["error"]?["type"]?.string,
            value["response"]?["error"]?["code"]?.string,
            value["message"]?.string,
            value["type"]?.string,
            value["code"]?.string,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if message.contains("rate limit") || message.contains("rate-limit") || message.contains("rate_limit") { return "rate" }
        if message.contains("quota") { return "quota" }
        if message.contains("credit") { return "credits" }
        if message.contains("usage limit") || message.contains("usage-limit") || message.contains("usage_limit") || message.contains("provider limit") || message.contains("provider_limit") || message.contains("resource exhausted") || message.contains("too many requests") || message.contains("billing limit") || message.contains("billing_limit") { return "usage" }
        if message.contains("insufficient balance") || message.contains("insufficient_balance") || message.contains("insufficient funds") || message.contains("insufficient_quota") { return "balance" }
        return nil
    }

    static func isRetryable(_ status: Int) -> Bool { status == 408 || status == 409 || status == 425 || status == 429 || (500..<600).contains(status) }

    static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
    }

    /// Output ceiling for an Anthropic request. Thinking is billed against the
    /// same budget as the answer, so deeper effort needs more room.
    static func maxTokens(forEffort effort: String) -> Int {
        switch effort {
        case "max": return 32_000
        case "xhigh": return 24_000
        case "high": return 16_000
        default: return 8_192
        }
    }

    static func jsonObject(from string: String) -> Any {
        guard let data = string.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }
}
