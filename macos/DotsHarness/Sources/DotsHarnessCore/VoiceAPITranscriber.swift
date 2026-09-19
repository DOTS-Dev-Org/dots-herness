// Copyright (c) 2026 DOTS
// OpenAI-compatible local/remote audio transcription.

import Foundation

public enum VoiceAPITranscriber {
    public static func transcribe(
        samples: [Float],
        sampleRate: Double,
        configuration: VoiceAPIConfiguration
    ) async throws -> String {
        guard configuration.isConfigured else {
            throw NativeAgentError(AppCopy.text("voice.apiSettingsMissing"))
        }

        let endpoint = try transcriptionURL(from: configuration.endpoint)
        let boundary = "DotsHarness-\(UUID().uuidString)"
        let audio = makeWAV(samples: samples, sampleRate: sampleRate)
        var body = Data()
        appendField("model", value: configuration.model, boundary: boundary, to: &body)
        appendField("response_format", value: "json", boundary: boundary, to: &body)
        appendFile(
            name: "file",
            filename: "recording.wav",
            mimeType: "audio/wav",
            data: audio,
            boundary: boundary,
            to: &body
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = String(data: data, encoding: .utf8) ?? AppCopy.format("voice.httpStatus", status)
            throw NativeAgentError(AppCopy.format("voice.apiError", String(detail.prefix(220))))
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw NativeAgentError(AppCopy.text("voice.apiNoTranscript"))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transcriptionURL(from rawValue: String) throws -> URL {
        guard var components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            throw NativeAgentError(AppCopy.text("voice.invalidAPIURL"))
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions") {
            if path.isEmpty { path = "/v1" }
            if !path.hasSuffix("/v1") { path += "/v1" }
            path += "/audio/transcriptions"
        }
        components.path = path
        guard let url = components.url else {
            throw NativeAgentError(AppCopy.text("voice.invalidAPIURL"))
        }
        return url
    }

    private static func appendField(_ name: String, value: String, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }

    private static func appendFile(
        name: String,
        filename: String,
        mimeType: String,
        data fileData: Data,
        boundary: String,
        to data: inout Data
    ) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }

    private static func makeWAV(samples: [Float], sampleRate: Double) -> Data {
        let rate = max(1, Int(sampleRate.rounded()))
        var pcm = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            pcm.appendLittleEndian(Int16(clipped * 32_767))
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(rate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var wav = Data("RIFF".utf8)
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(channels)
        wav.appendLittleEndian(UInt32(rate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

public final class VoiceAPIRealtimeClient: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable (VoiceTranscriptUpdate) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void

    private final class SocketBox: @unchecked Sendable {
        let task: URLSessionWebSocketTask

        init(task: URLSessionWebSocketTask) {
            self.task = task
        }
    }

    private enum Outgoing: Sendable {
        case data(Data)
        case text(String)
    }

    private actor Sender {
        let socket: SocketBox

        init(socket: SocketBox) {
            self.socket = socket
        }

        func send(_ message: Outgoing) async throws {
            switch message {
            case let .data(data):
                try await socket.task.send(.data(data))
            case let .text(text):
                try await socket.task.send(.string(text))
            }
        }

        func cancel() {
            socket.task.cancel(with: .goingAway, reason: nil)
        }
    }

    private let configuration: VoiceAPIConfiguration
    private let onUpdate: UpdateHandler
    private let onError: ErrorHandler
    private let lock = NSLock()
    private var sender: Sender?
    private var socket: SocketBox?
    private var receiveTask: Task<Void, Never>?
    private var isCancelled = false
    private var partialText = ""

    public init(
        configuration: VoiceAPIConfiguration,
        onUpdate: @escaping UpdateHandler,
        onError: @escaping ErrorHandler
    ) {
        self.configuration = configuration
        self.onUpdate = onUpdate
        self.onError = onError
    }

    deinit {
        cancel()
    }

    public func start() async throws {
        let url = try Self.realtimeURL(from: configuration)
        var request = URLRequest(url: url)
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.webSocketTask(with: request)
        let box = SocketBox(task: task)
        let sender = Sender(socket: box)
        task.resume()

        let first: URLSessionWebSocketTask.Message
        do {
            first = try await Self.receiveHandshake(from: task)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
        guard Self.eventType(from: first) == "session.created" else {
            task.cancel(with: .protocolError, reason: nil)
            throw NativeAgentError(AppCopy.text("voice.realtimeHandshakeFailed"))
        }

        setConnection(box, sender: sender)

        let update: [String: Any] = [
            "type": "session.update",
            "session": [
                "sample_rate": 16_000,
                "language": "auto",
                "automatic_punctuation": true,
                "endpointing_ms": 800,
            ],
        ]
        do {
            try await sender.send(.text(Self.json(update)))
        } catch {
            cancel()
            throw error
        }

        receiveTask = Task { [weak self, box] in
            await self?.receiveLoop(box)
        }
    }

    public func send(samples: [Float]) {
        let data = Self.makePCM16(samples)
        guard !data.isEmpty else { return }
        lock.lock()
        let sender = self.sender
        let cancelled = isCancelled
        lock.unlock()
        guard let sender, !cancelled else { return }
        Task {
            do {
                try await sender.send(.data(data))
            } catch {
                self.report(error)
            }
        }
    }

    public func commit() {
        sendJSON(["type": "input_audio_buffer.commit"])
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        let sender = self.sender
        let receiveTask = self.receiveTask
        self.sender = nil
        self.socket = nil
        self.receiveTask = nil
        lock.unlock()
        receiveTask?.cancel()
        Task { await sender?.cancel() }
    }

    private func sendJSON(_ object: [String: Any]) {
        lock.lock()
        let sender = self.sender
        let cancelled = isCancelled
        lock.unlock()
        guard let sender, !cancelled else { return }
        let payload = Self.json(object)
        Task {
            do {
                try await sender.send(.text(payload))
            } catch {
                self.report(error)
            }
        }
    }

    private func receiveLoop(_ box: SocketBox) async {
        do {
            while !Task.isCancelled {
                let message = try await box.task.receive()
                handle(message)
            }
        } catch {
            if shouldReportErrors { report(error) }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }

        if type == "error" {
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? AppCopy.text("voice.realtimeError")
            report(NativeAgentError(message))
            return
        }

        if type.contains("transcription.delta") {
            let delta = (object["delta"] as? String) ?? (object["text"] as? String) ?? ""
            guard !delta.isEmpty else { return }
            partialText += delta
            onUpdate(VoiceTranscriptUpdate(text: partialText, isFinal: false))
        } else if type.contains("transcription.completed") {
            let completed = (object["text"] as? String)
                ?? (object["transcript"] as? String)
                ?? partialText
            partialText = ""
            let text = completed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onUpdate(VoiceTranscriptUpdate(text: text, isFinal: true)) }
        } else if type.contains("speech_stopped") || type.contains("endpoint") {
            // Local VAD owns commits; the server endpoint only confirms completion.
        }
    }

    private func report(_ error: Error) {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if !cancelled { onError(error) }
    }

    private func setConnection(_ box: SocketBox, sender: Sender) {
        lock.lock()
        self.socket = box
        self.sender = sender
        self.isCancelled = false
        lock.unlock()
    }

    private var shouldReportErrors: Bool {
        lock.lock()
        let result = !isCancelled
        lock.unlock()
        return result
    }

    private static func eventType(from message: URLSessionWebSocketTask.Message) -> String? {
        let data: Data
        switch message {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: return nil
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["type"] as? String
    }

    private static func receiveHandshake(from task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func realtimeURL(from configuration: VoiceAPIConfiguration) throws -> URL {
        let raw = configuration.realtimeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = raw.isEmpty ? configuration.endpoint : raw
        guard var components = URLComponents(string: source),
              components.host != nil,
              components.scheme != nil else {
            throw NativeAgentError(AppCopy.text("voice.invalidAPIURL"))
        }

        if components.scheme == "http" { components.scheme = "ws" }
        if components.scheme == "https" { components.scheme = "wss" }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/realtime") {
            if path.isEmpty { path = "/v1" }
            if !path.hasSuffix("/v1") { path += "/v1" }
            path += "/realtime"
        }
        components.path = path
        guard let url = components.url else {
            throw NativeAgentError(AppCopy.text("voice.invalidAPIURL"))
        }
        return url
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    private static func makePCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            data.appendLittleEndian(Int16(clipped * 32_767))
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
