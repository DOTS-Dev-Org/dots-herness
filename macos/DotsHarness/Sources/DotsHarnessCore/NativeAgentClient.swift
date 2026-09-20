// Copyright (c) 2026 DOTS
// OpenAI-compatible transport used by the native agent loop.

import Foundation
import HarnessPluginKit
import PluginRuntime

public struct NativeAgentClient: Sendable {
    public var configuration: AgentConfiguration
    var session: URLSession

    public init(configuration: AgentConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func complete(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = [],
        cachePolicy: AgentCachePolicy = AgentCachePolicy()
    ) async throws -> AgentResponse {
        let body = makeBody(messages: messages, tools: tools, cachePolicy: cachePolicy)
        // Prompt caches match the prefix byte for byte; sorted keys keep tool
        // schemas identical across requests and app restarts.
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else {
            throw NativeAgentError(AppCopy.text("agent.encodeRequestFailed"))
        }

        let request = try makeRequest(
            body: data,
            accept: configuration.api == RouterAPIKind.chatGPT.rawValue ? "text/event-stream" : "application/json",
            sessionKey: cachePolicy.promptCacheKey
        )

        do {
            let (responseData, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let value = (try? JSONCodec.parse(responseData)) ?? .null
            guard (200..<300).contains(status) else {
                let message = Self.errorMessage(from: value, status: status)
                let imageUnsupported = messages.contains { message in
                    message.attachments.contains { $0.kind == .image }
                }
                    && VisionProviderCapability.isImageInputUnsupported(
                        message: message,
                        statusCode: status
                    )
                // Classify this before the Responses compaction fallback. An
                // image-capability failure is a provider decision, not a
                // malformed compaction request, and must not cause a second
                // image-bearing request before Vision gets a chance to run.
                if imageUnsupported {
                    throw NativeAgentError(
                        message,
                        statusCode: status,
                        retryable: Self.isRetryable(status),
                        isImageInputUnsupported: true
                    )
                }
                // `prompt_cache_key` goes to every OpenAI-style route; a strict
                // server that rejects unknown fields gets the same request again
                // without it.
                // ponytail: retried on every turn for such a server; remember the
                // rejection per endpoint if one turns up in practice.
                if [400, 422].contains(status),
                   body["prompt_cache_key"] != nil,
                   message.lowercased().contains("prompt_cache_key") {
                    return try await complete(messages: messages, tools: tools, cachePolicy: AgentCachePolicy())
                }
                if status == 400, configuration.supportsNativeCompaction {
                    var fallback = configuration
                    fallback.supportsNativeCompaction = false
                    var result = try await NativeAgentClient(configuration: fallback, session: session).complete(
                        messages: messages,
                        tools: tools,
                        cachePolicy: cachePolicy
                    )
                    result.nativeCompactionFallback = true
                    return result
                }
                throw NativeAgentError(
                    message,
                    statusCode: status,
                    retryable: Self.isRetryable(status),
                    isLimit: Self.limitKind(from: value, status: status) != nil,
                    retryAt: NativeAgentError.retryAt(from: response)
                )
            }
            var result: AgentResponse
            if configuration.api == RouterAPIKind.chatGPT.rawValue {
                result = try Self.responseFromSSE(responseData)
            } else if configuration.api == RouterAPIKind.geminiCLI.rawValue {
                result = try Self.geminiResponse(from: value)
            } else {
                result = try Self.response(from: value)
            }
            if configuration.api == RouterAPIKind.anthropic.rawValue {
                let cloaked = configuration.transportSpec?.quirks.cloakToolsOnOAuth == true && configuration.isOAuth
                result.message.toolCalls = result.message.toolCalls.map {
                    AgentToolCall(id: $0.id, name: ToolCloak.restore($0.name, cloaked: cloaked), arguments: $0.arguments)
                }
            }
            return result
        } catch let error as NativeAgentError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw NativeAgentError(error.localizedDescription, retryable: Self.isRetryable(error))
        }
    }

    /// Uses the selected Responses model's built-in image-generation tool.
    /// The tool returns the finished PNG as base64 in an image-generation call.
    public func generateImage(prompt: String, paths: SupportPaths) async throws -> ChatMedia {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NativeAgentError(AppCopy.text("media.promptMissing"))
        }
        guard configuration.api == RouterAPIKind.chatGPT.rawValue else {
            throw NativeAgentError(AppCopy.format("media.unsupported", MediaKind.image.displayName))
        }

        var body = makeResponsesBody(
            messages: [AgentMessage(role: .user, content: prompt)],
            tools: [],
            cachePolicy: AgentCachePolicy()
        )
        body["tools"] = [["type": "image_generation"]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw NativeAgentError(AppCopy.text("agent.encodeRequestFailed"))
        }
        let request = try makeRequest(body: data, accept: "text/event-stream")

        do {
            let (responseData, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let value = (try? JSONCodec.parse(responseData)) ?? .null
            guard (200..<300).contains(status) else {
                throw NativeAgentError(
                    Self.errorMessage(from: value, status: status),
                    statusCode: status,
                    retryable: Self.isRetryable(status),
                    isLimit: Self.limitKind(from: value, status: status) != nil,
                    retryAt: NativeAgentError.retryAt(from: response)
                )
            }
            let encoded = try Self.imageBase64FromResponse(responseData)
            let raw = encoded.components(separatedBy: ",").last ?? encoded
            guard let imageData = Data(base64Encoded: raw, options: .ignoreUnknownCharacters) else {
                throw NativeAgentError(AppCopy.text("media.invalidOutput"))
            }
            return try MediaGenerationClient.save(imageData, kind: .image, paths: paths)
        } catch let error as NativeAgentError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw NativeAgentError(error.localizedDescription, retryable: Self.isRetryable(error))
        }
    }
}

extension JSONValue {
    var firstObject: JSONObject? {
        guard case .array(let values) = self else { return nil }
        return values.first?.object
    }
}

extension Array where Element == JSONValue {
    var textBlocks: String { map { $0["text"]?.string ?? "" }.joined() }
}
