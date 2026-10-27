// Copyright (c) 2026 DOTS
// Serves one MLX model over OpenAI-compatible HTTP on loopback. Runs as a
// helper process so the weights live outside the app and leave with it.

import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Network
import Tokenizers

struct Options {
    var model = ""
    var host = "127.0.0.1"
    var port: UInt16 = 18765
    var maxTokens = 8192
    var idleSeconds = 15.0
    var temperature: Float = 0
    var topP: Float = 1
    var topK = 0
    var minP: Float = 0
    var repetitionPenalty: Float?

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            index += 2
            switch flag {
            case "--model": model = value
            case "--host": host = value
            case "--port": port = UInt16(value) ?? port
            case "--max-tokens": maxTokens = Int(value) ?? maxTokens
            case "--idle-seconds": idleSeconds = Double(value) ?? idleSeconds
            case "--temp": temperature = Float(value) ?? temperature
            case "--top-p": topP = Float(value) ?? topP
            case "--top-k": topK = Int(value) ?? topK
            case "--min-p": minP = Float(value) ?? minP
            case "--repetition-penalty": repetitionPenalty = Float(value)
            default:
                log("ignored argument \(flag)")
                index -= 1
            }
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[dotsmlx] \(message)\n".utf8))
}

struct HTTPError: Error {
    var status: Int
    var message: String
}

/// JSONSerialization output as the plain Swift values a chat template takes.
/// Nulls are dropped: templates test for a missing key, not for `none`.
func plain(_ value: Any) -> (any Sendable)? {
    switch value {
    case let string as String: return string
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return CFNumberIsFloatType(number) ? number.doubleValue : number.intValue
    case let array as [Any]: return array.compactMap(plain)
    case let object as [String: Any]: return object.compactMapValues(plain)
    default: return nil
    }
}

/// OpenAI messages as the dictionaries a chat template takes: text parts are
/// joined, and tool-call arguments become objects instead of JSON strings.
func templateMessages(_ messages: [[String: Any]]) -> [Message] {
    messages.map { message in
        var result: Message = ["role": message["role"] as? String ?? "user"]
        if let parts = message["content"] as? [[String: Any]] {
            result["content"] = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            result["content"] = message["content"] as? String ?? ""
        }
        for key in ["name", "tool_call_id"] {
            if let value = message[key] as? String { result[key] = value }
        }
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            result["tool_calls"] = calls.map { call -> [String: any Sendable] in
                var function = call["function"] as? [String: Any] ?? [:]
                if let text = function["arguments"] as? String {
                    function["arguments"] = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [String: Any]()
                }
                var copy = call
                copy["function"] = function
                return copy.compactMapValues(plain)
            }
        }
        return result
    }
}

/// The KV cache of the last prompt, so an agent's next turn only feeds the new
/// tokens. Touched only while the engine's turn lock is held.
final class PromptCache: @unchecked Sendable {
    var cache: [KVCache]?
    var tokens: [Int32] = []
}

actor Engine {
    struct Turn {
        var stream: AsyncStream<Generation>
        var promptTokens: Int
        var cachedTokens: Int
    }

    private let options: Options
    private var container: ModelContainer?
    private let promptCache = PromptCache()
    private var lastUse = Date()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(options: Options) { self.options = options }

    /// One generation at a time: a second request would split the GPU and the cache.
    func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
    }

    func release(clean: Bool) {
        // An abandoned stream may still be writing to its cache.
        if !clean { promptCache.cache = nil }
        lastUse = Date()
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    func load() async throws -> ModelContainer {
        if let container { return container }
        let started = Date()
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: options.model), using: #huggingFaceTokenizerLoader()
        )
        container = loaded
        lastUse = Date()
        log(String(format: "model loaded in %.1f s", Date().timeIntervalSince(started)))
        return loaded
    }

    /// Weights and KV cache leave memory when nothing asked for them for a
    /// while; the next request loads them again.
    func unloadIfIdle() {
        guard options.idleSeconds > 0, !busy, container != nil,
              Date().timeIntervalSince(lastUse) >= options.idleSeconds else { return }
        container = nil
        promptCache.cache = nil
        promptCache.tokens = []
        Memory.clearCache()
        log("idle: model unloaded")
    }

    func begin(_ body: [String: Any]) async throws -> Turn {
        guard let messages = body["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw HTTPError(status: 400, message: "messages is required")
        }
        let wantsTools = (body["tool_choice"] as? String) != "none"
        let tools = wantsTools ? (body["tools"] as? [[String: Any]])?.map { $0.compactMapValues(plain) } : nil
        let limit = (body["max_tokens"] ?? body["max_completion_tokens"]) as? Int ?? options.maxTokens
        func number(_ key: String) -> Float? { (body[key] as? NSNumber)?.floatValue }
        let parameters = GenerateParameters(
            maxTokens: limit,
            temperature: number("temperature") ?? options.temperature,
            topP: number("top_p") ?? options.topP,
            topK: body["top_k"] as? Int ?? options.topK,
            minP: number("min_p") ?? options.minP,
            repetitionPenalty: number("repetition_penalty") ?? options.repetitionPenalty,
            presencePenalty: number("presence_penalty"),
            frequencyPenalty: number("frequency_penalty"),
            seed: (body["seed"] as? NSNumber)?.uint64Value
        )
        let stops = Set((body["stop"] as? [String]) ?? (body["stop"] as? String).map { [$0] } ?? [])

        let container = try await load()
        let input = try await container.prepare(input: UserInput(messages: templateMessages(messages), tools: tools))
        let promptCache = promptCache
        return try await container.perform(nonSendable: input) { context, input in
            let tokens = input.text.tokens.reshaped(-1).asArray(Int32.self)
            var feed = input
            var reused = 0
            if let cache = promptCache.cache, canTrimPromptCache(cache), let offset = cache.first?.offset {
                // Always feed at least the last token: generation needs its logits.
                let common = zip(tokens, promptCache.tokens).prefix { $0 == $1 }.count
                reused = min(common, tokens.count - 1, offset)
                if reused > 0 {
                    trimPromptCache(cache, numTokens: offset - reused)
                    feed = LMInput(tokens: MLXArray(Array(tokens[reused...])))
                }
            }
            if reused == 0 { promptCache.cache = try context.model.newCache(parameters: parameters) }
            promptCache.tokens = tokens
            var context = context
            if !stops.isEmpty {
                context.configuration.stopStrings = context.configuration.effectiveStopStrings.union(stops)
            }
            let stream = try MLXLMCommon.generate(
                input: feed, cache: promptCache.cache, parameters: parameters, context: context, tools: tools
            )
            return Turn(stream: stream, promptTokens: tokens.count, cachedTokens: reused)
        }
    }
}

// MARK: HTTP

extension NWConnection {
    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let error { return continuation.resume(throwing: error) }
                continuation.resume(returning: data?.isEmpty == false ? data : (complete ? nil : Data()))
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func respond(_ status: Int, _ object: Any) async throws {
        let body = try JSONSerialization.data(withJSONObject: object)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try await write(Data(head.utf8) + body)
    }
}

struct Request {
    var method: String
    var path: String
    var body: Data
}

/// One request per connection; every response closes it.
func readRequest(_ connection: NWConnection) async throws -> Request? {
    var buffer = Data()
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Data.Index?
    while headerEnd == nil {
        guard let chunk = try await connection.read() else { return nil }
        buffer.append(chunk)
        headerEnd = buffer.range(of: separator)?.upperBound
        if buffer.count > 1 << 16, headerEnd == nil { throw HTTPError(status: 400, message: "headers too large") }
    }
    guard let headerEnd, let head = String(data: buffer[..<headerEnd], encoding: .utf8) else { return nil }
    let lines = head.components(separatedBy: "\r\n")
    let start = lines[0].split(separator: " ")
    guard start.count >= 2 else { throw HTTPError(status: 400, message: "bad request line") }
    let length = lines.dropFirst().compactMap { line -> Int? in
        let pair = line.split(separator: ":", maxSplits: 1)
        guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
        return Int(pair[1].trimmingCharacters(in: .whitespaces))
    }.first ?? 0
    // Loopback only, but a prompt is never this large.
    guard length <= 256 << 20 else { throw HTTPError(status: 413, message: "body too large") }
    var body = Data(buffer[headerEnd...])
    while body.count < length {
        guard let chunk = try await connection.read() else { return nil }
        body.append(chunk)
    }
    return Request(method: String(start[0]), path: String(start[1].split(separator: "?")[0]), body: body)
}

let modelID = "default_model"

func chat(_ connection: NWConnection, body: [String: Any], engine: Engine) async throws {
    await engine.acquire()
    var clean = false
    let turn: Engine.Turn
    do { turn = try await engine.begin(body) } catch {
        await engine.release(clean: false)
        throw error
    }
    defer { Task { [clean] in await engine.release(clean: clean) } }

    let streaming = body["stream"] as? Bool == true
    let includeUsage = ((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool) == true
    let id = "chatcmpl-\(UUID().uuidString)"
    let created = Int(Date().timeIntervalSince1970)
    func chunk(delta: [String: Any], finish: String? = nil) -> Data {
        let object: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "created": created, "model": modelID,
            "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]],
        ]
        return Data("data: ".utf8) + (try! JSONSerialization.data(withJSONObject: object)) + Data("\n\n".utf8)
    }

    if streaming {
        try await connection.write(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8))
        try await connection.write(chunk(delta: ["role": "assistant", "content": ""]))
    }
    var text = ""
    var calls: [[String: Any]] = []
    var info: GenerateCompletionInfo?
    for await event in turn.stream {
        switch event {
        case .chunk(let piece):
            text += piece
            if streaming { try await connection.write(chunk(delta: ["content": piece])) }
        case .toolCall(let call):
            let arguments = String(data: try JSONEncoder().encode(call.function.arguments), encoding: .utf8) ?? "{}"
            var entry: [String: Any] = [
                "id": call.id ?? "call_\(UUID().uuidString.prefix(12))", "type": "function",
                "function": ["name": call.function.name, "arguments": arguments],
            ]
            if streaming {
                entry["index"] = calls.count
                try await connection.write(chunk(delta: ["tool_calls": [entry]]))
            }
            calls.append(entry)
        case .rejectedToolCall(let rejection):
            // Unparseable call: hand the raw text over rather than answer with nothing.
            log("rejected tool call: \(rejection.reason)")
            text += rejection.rawTextPreview
            if streaming { try await connection.write(chunk(delta: ["content": rejection.rawTextPreview])) }
        case .info(let value):
            info = value
        }
    }
    clean = info != nil
    let finish: String
    switch info?.stopReason {
    case .length: finish = "length"
    default: finish = calls.isEmpty ? "stop" : "tool_calls"
    }
    let completion = info?.generationTokenCount ?? 0
    let usage: [String: Any] = [
        "prompt_tokens": turn.promptTokens, "completion_tokens": completion,
        "total_tokens": turn.promptTokens + completion,
        "prompt_tokens_details": ["cached_tokens": turn.cachedTokens],
    ]
    if streaming {
        try await connection.write(chunk(delta: [:], finish: finish))
        if includeUsage {
            let object: [String: Any] = [
                "id": id, "object": "chat.completion.chunk", "created": created, "model": modelID,
                "choices": [], "usage": usage,
            ]
            try await connection.write(Data("data: ".utf8) + JSONSerialization.data(withJSONObject: object) + Data("\n\n".utf8))
        }
        try await connection.write(Data("data: [DONE]\n\n".utf8))
    } else {
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !calls.isEmpty { message["tool_calls"] = calls }
        try await connection.respond(200, [
            "id": id, "object": "chat.completion", "created": created, "model": modelID,
            "choices": [["index": 0, "message": message, "finish_reason": finish]], "usage": usage,
        ] as [String: Any])
    }
}

func serve(_ connection: NWConnection, engine: Engine) async {
    defer { connection.cancel() }
    do {
        guard let request = try await readRequest(connection) else { return }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            try await connection.respond(200, ["status": "ok"])
        case ("GET", "/v1/models"):
            try await connection.respond(200, ["object": "list", "data": [["id": modelID, "object": "model"]]])
        case ("POST", "/v1/chat/completions"):
            guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                throw HTTPError(status: 400, message: "body is not a JSON object")
            }
            try await chat(connection, body: body, engine: engine)
        default:
            throw HTTPError(status: 404, message: "not found")
        }
    } catch let error as HTTPError {
        try? await connection.respond(error.status, ["error": ["message": error.message]])
    } catch is NWError {
        // The client went away; nothing to answer.
    } catch {
        log("request failed: \(error)")
        try? await connection.respond(500, ["error": ["message": error.localizedDescription]])
    }
}

// MARK: Main

let options = Options(Array(CommandLine.arguments.dropFirst()))
guard !options.model.isEmpty, let port = NWEndpoint.Port(rawValue: options.port) else {
    log("usage: dotsmlx --model <directory> [--host 127.0.0.1] [--port 18765] [--max-tokens 8192] [--idle-seconds 15] [--temp 0] [--top-p 1] [--top-k 0] [--min-p 0] [--repetition-penalty 1.1]")
    exit(2)
}
let engine = Engine(options: options)

Task {
    // /health answers only once the weights are in, as the app waits on it.
    do { _ = try await engine.load() } catch {
        log("model failed to load: \(error)")
        exit(1)
    }
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(options.host), port: port)
    guard let listener = try? NWListener(using: parameters) else {
        log("cannot listen on \(options.host):\(options.port)")
        exit(1)
    }
    listener.stateUpdateHandler = { state in
        if case .failed(let error) = state {
            log("listener failed: \(error)")
            exit(1)
        }
    }
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        Task { await serve(connection, engine: engine) }
    }
    listener.start(queue: .global())
    log("listening on \(options.host):\(options.port)")

    while true {
        try? await Task.sleep(for: .seconds(15))
        // The app died without stopping us: do not keep its model resident.
        if getppid() == 1 { exit(0) }
        await engine.unloadIfIdle()
    }
}
dispatchMain()
