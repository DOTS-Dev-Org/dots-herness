// Copyright (c) 2026 DOTS
// Loopback-only, non-streaming gateway for explicitly enabled sharing.

import Foundation
import Network

public struct GatewayRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
}

public struct GatewayResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data = Data(), contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public static func json(_ object: Any, status: Int = 200) -> GatewayResponse {
        GatewayResponse(
            status: status,
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        )
    }
}

public final class ProviderGateway: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private let handler: @Sendable (GatewayRequest) async -> GatewayResponse
    private var listener: NWListener?

    public private(set) var running = false

    public init(
        port: UInt16 = 18766,
        handler: @escaping @Sendable (GatewayRequest) async -> GatewayResponse
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw RouterTestError.message("Invalid gateway port") }
        self.port = port
        self.handler = handler
    }

    public var url: URL { URL(string: "http://127.0.0.1:\(port.rawValue)/v1")! }

    public func start() throws {
        guard !running else { return }
        // Bind to loopback explicitly. NWListener(using:on:) otherwise listens on
        // 0.0.0.0, exposing the gateway to the LAN despite the "loopback-only" intent.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [handler] connection in
            connection.start(queue: .main)
            Self.receiveRequest(connection, buffer: Data()) { data in
                Task {
                    let request = Self.parse(data)
                    let response = await handler(request)
                    connection.send(content: Self.httpData(response), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.running = true }
            if case .failed = state { self?.running = false }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    /// Keep reading until the headers and the full Content-Length body have arrived.
    /// A single receive() drops any body that lands in a later TCP segment.
    private static func receiveRequest(
        _ connection: NWConnection,
        buffer: Data,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, error in
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if error != nil || isComplete || buffer.count > 8_388_608 || messageComplete(buffer) {
                completion(buffer)
            } else {
                receiveRequest(connection, buffer: buffer, completion: completion)
            }
        }
    }

    private static func messageComplete(_ data: Data) -> Bool {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator) else { return false }
        let headerText = String(data: data.subdata(in: data.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
        let contentLength = headerText.components(separatedBy: "\r\n").dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1])
        }.first ?? 0
        return data.distance(from: range.upperBound, to: data.endIndex) >= contentLength
    }

    private static func parse(_ data: Data) -> GatewayRequest {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator) else {
            return GatewayRequest(method: "", path: "", headers: [:], body: Data())
        }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        let bodyStart = range.upperBound
        let body = data.subdata(in: bodyStart..<data.endIndex)
        let lines = String(data: headerData, encoding: .utf8)?.components(separatedBy: "\r\n") ?? []
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return GatewayRequest(method: requestLine.first ?? "", path: requestLine.count > 1 ? requestLine[1] : "", headers: headers, body: body)
    }

    private static func httpData(_ response: GatewayResponse) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"][response.status] ?? "Error"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
