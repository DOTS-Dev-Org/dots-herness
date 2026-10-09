// Copyright (c) 2026 DOTS
// Finds local OpenAI-compatible servers the user already runs, and reads the
// context window they actually serve.

import CoreFoundation
import Foundation

public enum LocalServerDiscovery {
    public struct Server: Identifiable, Sendable, Equatable {
        public var name: String
        public var baseURL: String
        public var modelCount: Int
        public var id: String { baseURL }
    }

    /// Default ports of the common local runtimes. Port 8080 is shared by
    /// llama.cpp's `llama-server` and engines built on it (Strata, …).
    public static let candidates: [(name: String, port: Int)] = [
        ("Ollama", 11434),
        ("LM Studio", 1234),
        ("llama.cpp", 8080),
        ("Jan", 1337),
        ("KoboldCpp", 5001),
        ("vLLM", 8000),
    ]

    public static func scan(session: URLSession = .shared) async -> [Server] {
        await withTaskGroup(of: Server?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let base = "http://127.0.0.1:\(candidate.port)/v1"
                    guard let count = await modelCount(base: base, session: session) else { return nil }
                    return Server(name: candidate.name, baseURL: base, modelCount: count)
                }
            }
            var found: [Server] = []
            for await server in group { if let server { found.append(server) } }
            let order = candidates.map(\.name)
            return found.sorted { (order.firstIndex(of: $0.name) ?? 0) < (order.firstIndex(of: $1.name) ?? 0) }
        }
    }

    /// Only an OpenAI-shaped `/models` answer counts; any other service on the
    /// port (a dev server on 8080, say) is ignored.
    private static func modelCount(base: String, session: URLSession) async -> Int? {
        guard let object = await LocalServerProbe.json(base + "/models", session: session) as? [String: Any],
              let data = object["data"] as? [[String: Any]] else { return nil }
        return data.count
    }
}

public enum LocalServerProbe {
    /// Key for a context that applies to every model of a single-model server.
    public static let anyModel = "*"

    /// Context windows by model id, as the server is serving them right now.
    /// Empty when the server exposes none of the known introspection endpoints.
    public static func contextWindows(
        baseURL: String,
        modelIDs: [String] = [],
        session: URLSession = .shared
    ) async -> [String: Int] {
        var root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if root.hasSuffix("/v1") { root.removeLast(3) }

        // llama.cpp `llama-server` (and forks): one model, one real n_ctx.
        if let props = await json(root + "/props", session: session) as? [String: Any],
           let settings = props["default_generation_settings"] as? [String: Any],
           let context = settings["n_ctx"] as? Int, context > 0 {
            return [anyModel: context]
        }
        // LM Studio: loaded context when a model is in memory, else its maximum.
        if let object = await json(root + "/api/v0/models", session: session) as? [String: Any],
           let rows = object["data"] as? [[String: Any]] {
            let values = contexts(rows, id: "id", keys: ["loaded_context_length", "max_context_length"])
            if !values.isEmpty { return values }
        }
        // Ollama: only loaded models report the context they run with. Its
        // OpenAI endpoint cannot change it, so an unloaded model stays unknown.
        var result: [String: Int] = [:]
        if let object = await json(root + "/api/ps", session: session) as? [String: Any],
           let rows = object["models"] as? [[String: Any]] {
            result = contexts(rows, id: "name", keys: ["context_length"])
        }

        // Ollama's `/api/show` reports the model's architecture context limit.
        // `/api/ps` above remains authoritative for a model currently loaded
        // with a smaller runtime context.
        guard let tags = await json(root + "/api/tags", session: session) as? [String: Any],
              tags["models"] is [[String: Any]] else { return result }
        let ids = Array(Set(modelIDs.filter { !$0.isEmpty })).sorted()
        let runningModels = Set(result.keys)
        let showURL = root + "/api/show"
        let discovered = await withTaskGroup(of: (String, Int?).self) { group in
            for id in ids where !runningModels.contains(id) {
                group.addTask {
                    guard let response = await postJSON(showURL, body: ["model": id], session: session),
                          let object = response as? [String: Any],
                          let info = object["model_info"] as? [String: Any] else { return (id, nil) }
                    let limit = info.first { $0.key.lowercased().hasSuffix(".context_length") }?.value as? NSNumber
                    guard let limit, CFGetTypeID(limit) != CFBooleanGetTypeID(), limit.intValue > 0 else { return (id, nil) }
                    return (id, limit.intValue)
                }
            }
            var values: [String: Int] = [:]
            for await (id, context) in group {
                if let context, context > 0 { values[id] = context }
            }
            return values
        }
        for (id, context) in discovered { result[id] = context }
        return result
    }

    public static func contexts(_ rows: [[String: Any]], id: String, keys: [String]) -> [String: Int] {
        rows.reduce(into: [:]) { result, row in
            guard let name = row[id] as? String else { return }
            if let context = keys.lazy.compactMap({ row[$0] as? Int }).first(where: { $0 > 0 }) {
                result[name] = context
            }
        }
    }

    static func json(_ string: String, session: URLSession) async -> Any? {
        guard let url = URL(string: string) else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 1.5)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func postJSON(_ string: String, body: [String: String], session: URLSession) async -> Any? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
