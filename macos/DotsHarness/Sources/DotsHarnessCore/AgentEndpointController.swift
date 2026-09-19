// Copyright (c) 2026 DOTS
// Direct OpenAI-compatible endpoint configuration for the native agent.

import Foundation
import HarnessPluginKit

public struct EndpointModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var owner: String

    public init(id: String, owner: String = "") {
        self.id = id
        self.owner = owner
    }
}

public struct AgentEndpointError: Error, Sendable, LocalizedError, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Holds a direct model endpoint without starting or probing any service.
/// Network discovery is explicit and only runs when the user asks for it.
@MainActor
public final class AgentEndpointController: ObservableObject {
    @Published public var baseURL: String
    @Published public var modelID: String
    @Published public var apiKey: String
    @Published public private(set) var models: [EndpointModel] = []
    @Published public private(set) var reachable = false
    @Published public private(set) var status = AppCopy.text("endpoint.configure")
    @Published public private(set) var error: String?

    public init(baseURL: String = "", modelID: String = "", apiKey: String = "") {
        self.baseURL = baseURL
        self.modelID = modelID
        self.apiKey = apiKey
        updateStatus()
    }

    public var configuration: AgentConfiguration? {
        let endpoint = normalizedBaseURL
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !model.isEmpty else { return nil }
        return AgentConfiguration(
            baseURL: endpoint,
            model: model,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            compactionPolicy: AgentContextCompactionPolicy.current()
        )
    }

    public var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func updateStatus() {
        if let configuration {
            status = AppCopy.format("endpoint.ready", configuration.model)
        } else if normalizedBaseURL.isEmpty {
            status = AppCopy.text("endpoint.addEndpoint")
        } else if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = AppCopy.text("endpoint.chooseModel")
        } else {
            status = AppCopy.text("endpoint.readyToConnect")
        }
    }

    public func refreshModels() async {
        error = nil
        reachable = false

        guard let url = modelsURL else {
            models = []
            error = AppCopy.text("endpoint.invalidURL")
            status = error ?? status
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = configuration?.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                throw AgentEndpointError(AppCopy.format("endpoint.modelListFailed", statusCode))
            }
            let value = try JSONCodec.parse(data)
            guard case .array(let values) = value["data"] else {
                throw AgentEndpointError(AppCopy.text("endpoint.noModelList"))
            }
            models = values.compactMap { item in
                guard let id = item["id"]?.string, !id.isEmpty else { return nil }
                return EndpointModel(id: id, owner: item["owned_by"]?.string ?? "")
            }
            reachable = true
            updateStatus()
        } catch is CancellationError {
            return
        } catch {
            models = []
            self.error = error.localizedDescription
            status = AppCopy.text("endpoint.unavailable")
        }
    }

    private var modelsURL: URL? {
        guard var components = URLComponents(string: normalizedBaseURL),
              components.scheme != nil,
              components.host != nil else { return nil }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            path = "v1"
        } else if path.hasSuffix("/v1") == false {
            path += "/v1"
        }
        components.path = "/\(path)/models"
        return components.url
    }
}
