// Copyright (c) 2026 DOTS
// Codex /responses over a persistent WebSocket, the transport the Codex CLI uses.

import Foundation
import os

/// One open Codex socket. The backend keeps the last response on the connection
/// (`store` stays false), so the next step names it and sends only the new items.
final class CodexSocket: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let createdAt = Date()
    var busy = false
    var idleClose: Task<Void, Never>?
    private var lastBody: [String: Any]?
    private var lastResponseID: String?
    private var lastOutput: [Any] = []

    init(task: URLSessionWebSocketTask) { self.task = task }

    /// The request to send: `body` itself, or only its new input when it extends
    /// the last exchange on this socket.
    func request(for body: [String: Any]) -> [String: Any] {
        guard let lastBody, let lastResponseID,
              let delta = NativeAgentClient.codexInputDelta(body: body, lastBody: lastBody, lastOutput: lastOutput)
        else { return body }
        var request = body
        request["input"] = delta
        request["previous_response_id"] = lastResponseID
        return request
    }

    func remember(body: [String: Any]?, responseID: String?, output: [Any]) {
        lastBody = body
        lastResponseID = responseID
        lastOutput = output
    }
}

actor CodexSocketPool {
    static let shared = CodexSocketPool()
    // ponytail: pi's numbers; the server may drop an idle socket sooner, a reused dead one is retried fresh.
    static let idleTTL: TimeInterval = 5 * 60
    static let maxAge: TimeInterval = 55 * 60
    static let fallbackWindow: TimeInterval = 10 * 60

    private var sockets: [String: CodexSocket] = [:]
    private var disabledUntil: [String: Date] = [:]

    /// Nil sends the request over HTTP: WebSocket recently failed for this key, or
    /// another request of the same conversation holds its socket.
    func checkout(key: String, request: URLRequest, session: URLSession) -> (socket: CodexSocket, reused: Bool)? {
        if let until = disabledUntil[key], until > Date() { return nil }
        if let socket = sockets[key] {
            if socket.busy { return nil }
            socket.idleClose?.cancel()
            if socket.task.state == .running, Date().timeIntervalSince(socket.createdAt) < Self.maxAge {
                socket.busy = true
                return (socket, true)
            }
            socket.task.cancel(with: .goingAway, reason: nil)
        }
        let task = session.webSocketTask(with: request)
        // `response.completed` repeats the whole output; the 1 MB default is too small.
        task.maximumMessageSize = 64 << 20
        task.resume()
        let socket = CodexSocket(task: task)
        socket.busy = true
        sockets[key] = socket
        return (socket, false)
    }

    func checkin(key: String, socket: CodexSocket, keep: Bool) {
        socket.busy = false
        guard keep, sockets[key] === socket else {
            socket.task.cancel(with: .goingAway, reason: nil)
            if sockets[key] === socket { sockets[key] = nil }
            return
        }
        socket.idleClose = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTTL))
            guard !Task.isCancelled else { return }
            await self?.expire(key: key, socket: socket)
        }
    }

    func disable(key: String) {
        disabledUntil[key] = Date().addingTimeInterval(Self.fallbackWindow)
    }

    private func expire(key: String, socket: CodexSocket) {
        guard !socket.busy, sockets[key] === socket else { return }
        socket.task.cancel(with: .goingAway, reason: nil)
        sockets[key] = nil
    }
}

extension NativeAgentClient {
    private static let webSocketLog = Logger(subsystem: "com.dots.herness", category: "codex-websocket")
    static let codexWebSocketBeta = "responses_websockets=2026-02-06"
    /// Per-request settings the backend takes fresh on every step; they do not
    /// invalidate the state kept on the connection.
    static let codexVolatileKeys: Set<String> = ["input", "previous_response_id", "max_output_tokens", "prompt_cache_options"]

    /// The ChatGPT backend (not every Responses-shaped route) serves WebSocket.
    var usesCodexWebSocket: Bool {
        configuration.api == RouterAPIKind.chatGPT.rawValue
            && configuration.transportSpec?.quirks.requiresSessionAccountID == true
    }

    /// The new input items when `body` only extends the last request plus its
    /// output; nil when anything else changed and the full body must be sent.
    static func codexInputDelta(body: [String: Any], lastBody: [String: Any], lastOutput: [Any]) -> [Any]? {
        guard sameJSON(body.filter { !codexVolatileKeys.contains($0.key) },
                       lastBody.filter { !codexVolatileKeys.contains($0.key) }),
              let input = body["input"] as? [Any],
              let lastInput = lastBody["input"] as? [Any] else { return nil }
        let baseline = lastInput + lastOutput
        guard input.count > baseline.count, sameJSON(Array(input.prefix(baseline.count)), baseline) else { return nil }
        return Array(input.dropFirst(baseline.count))
    }

    private static func sameJSON(_ a: Any, _ b: Any) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: a, options: .sortedKeys),
              let right = try? JSONSerialization.data(withJSONObject: b, options: .sortedKeys) else { return false }
        return left == right
    }

    /// The streamed reply as SSE-shaped data, over WebSocket when this route has
    /// one and over HTTP otherwise.
    func streamedData(
        for request: URLRequest,
        body: [String: Any],
        cachePolicy: AgentCachePolicy,
        onDelta: StreamDeltaHandler?
    ) async throws -> (Data, URLResponse, Int?) {
        if usesCodexWebSocket, let key = Self.codexSocketKey(cachePolicy),
           let result = try await codexWebSocketData(for: request, body: body, sessionKey: key, onDelta: onDelta) {
            return result
        }
        return try await Self.dataTimingFirstDelta(for: request, session: session, api: configuration.api, onDelta: onDelta)
    }

    /// One socket per conversation: the cache key is shared by every chat of a
    /// project, so parallel chats would contend for one socket and switching chats
    /// would break the delta. One-off calls carry no cache key; a socket each would
    /// only cost a handshake.
    static func codexSocketKey(_ cachePolicy: AgentCachePolicy) -> String? {
        guard let key = cachePolicy.promptCacheKey, !key.isEmpty else { return nil }
        guard let scope = cachePolicy.comparisonScope, !scope.isEmpty else { return key }
        return key + "|" + scope
    }

    private enum CodexExchange {
        case completed(StreamCollector)
        /// An `error` event: the backend's status, headers and error body.
        case rejected(status: Int, headers: [String: String], body: Data, code: String?)
        /// The socket failed before the backend answered at all.
        case notStarted(handshakeStatus: Int?)
    }

    /// Nil means WebSocket is unavailable right now; the caller sends the same
    /// request over HTTP.
    private func codexWebSocketData(
        for request: URLRequest,
        body: [String: Any],
        sessionKey: String,
        onDelta: StreamDeltaHandler?
    ) async throws -> (Data, URLResponse, Int?)? {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        guard let socketURL = components.url else { return nil }
        var socketRequest = URLRequest(url: socketURL, timeoutInterval: request.timeoutInterval)
        for (name, value) in request.allHTTPHeaderFields ?? [:]
        where !["accept", "content-type", "content-length"].contains(name.lowercased()) {
            socketRequest.setValue(value, forHTTPHeaderField: name)
        }
        socketRequest.setValue(Self.codexWebSocketBeta, forHTTPHeaderField: "OpenAI-Beta")
        let key = [socketURL.absoluteString, request.value(forHTTPHeaderField: "ChatGPT-Account-ID") ?? "", sessionKey]
            .joined(separator: "|")
        let pool = CodexSocketPool.shared
        var fullBodyOnly = false
        // At most: a dead reused socket, then a lost continuation, then the answer.
        for _ in 0..<3 {
            guard let (socket, reused) = await pool.checkout(key: key, request: socketRequest, session: session) else { return nil }
            let sent = fullBodyOnly ? body : socket.request(for: body)
            let isDelta = sent["previous_response_id"] != nil
            // Unknown until this exchange completes.
            socket.remember(body: nil, responseID: nil, output: [])
            let outcome: CodexExchange
            do {
                outcome = try await exchange(on: socket.task, body: sent, timeout: request.timeoutInterval, onDelta: onDelta)
            } catch {
                await pool.checkin(key: key, socket: socket, keep: false)
                throw error
            }
            switch outcome {
            case .completed(let collector):
                let response = try? Self.responseFromSSE(collector.data)
                socket.remember(
                    body: body,
                    responseID: response?.providerResponseID,
                    output: response?.message.providerItems.map { $0.mapValues { $0.any } } ?? []
                )
                await pool.checkin(key: key, socket: socket, keep: true)
                Self.webSocketLog.debug("""
                    codex ws \(reused ? "reused" : "new", privacy: .public) \
                    \(isDelta ? "delta" : "full", privacy: .public) \
                    items=\((sent["input"] as? [Any])?.count ?? 0, privacy: .public)
                    """)
                guard let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return nil }
                return (collector.data, ok, collector.firstDelta)
            case .rejected(let status, let headers, let errorBody, let code):
                await pool.checkin(key: key, socket: socket, keep: false)
                if code == "previous_response_not_found", isDelta {
                    fullBodyOnly = true
                    continue
                }
                if code == "websocket_connection_limit_reached" { return nil }
                guard let rejected = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
                else { return nil }
                return (errorBody, rejected, nil)
            case .notStarted(let handshakeStatus):
                await pool.checkin(key: key, socket: socket, keep: false)
                if reused { continue }
                // An expired token is HTTP's to report and refresh; anything else
                // keeps this conversation on HTTP for a while.
                if handshakeStatus != 401 { await pool.disable(key: key) }
                Self.webSocketLog.info("codex ws unavailable, status=\(handshakeStatus ?? 0, privacy: .public); using HTTP")
                return nil
            }
        }
        return nil
    }

    private func exchange(
        on task: URLSessionWebSocketTask,
        body: [String: Any],
        timeout: TimeInterval,
        onDelta: StreamDeltaHandler?
    ) async throws -> CodexExchange {
        var frame = body
        frame["type"] = "response.create"
        guard let json = try? JSONSerialization.data(withJSONObject: frame, options: .sortedKeys) else {
            throw NativeAgentError(AppCopy.text("agent.encodeRequestFailed"))
        }
        var collector = StreamCollector(api: configuration.api, onDelta: onDelta)
        var started = false
        // The HTTP path's idle timeout: a socket silent this long is cancelled.
        let lastActivity = OSAllocatedUnfairLock(initialState: Date())
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Date().timeIntervalSince(lastActivity.withLock { $0 }) > timeout {
                    timedOut.withLock { $0 = true }
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        do {
            try await task.send(.string(String(decoding: json, as: UTF8.self)))
            while true {
                let message = try await withTaskCancellationHandler {
                    try await task.receive()
                } onCancel: {
                    task.cancel(with: .goingAway, reason: nil)
                }
                lastActivity.withLock { $0 = Date() }
                var text: String
                switch message {
                case .string(let string): text = string
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: continue
                }
                started = true
                // One event is one SSE line; raw newlines are only JSON whitespace.
                if text.contains("\n") { text = text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "") }
                guard let event = try? JSONCodec.parse(Data(text.utf8)) else { continue }
                let type = event["type"]?.string ?? ""
                if type == "error" {
                    let headers = event["headers"]?.object?.compactMapValues { $0.string ?? $0.int.map(String.init) } ?? [:]
                    return .rejected(
                        status: Self.streamFailure(in: event, fallback: "").status,
                        headers: headers,
                        body: Data(text.utf8),
                        code: event["error"]?["code"]?.string ?? event["code"]?.string
                    )
                }
                await collector.consume("data: " + text)
                if ["response.completed", "response.done", "response.incomplete", "response.failed"].contains(type) {
                    await collector.finish()
                    return .completed(collector)
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if timedOut.withLock({ $0 }) { throw URLError(.timedOut) }
            if !started { return .notStarted(handshakeStatus: (task.response as? HTTPURLResponse)?.statusCode) }
            throw error
        }
    }
}
