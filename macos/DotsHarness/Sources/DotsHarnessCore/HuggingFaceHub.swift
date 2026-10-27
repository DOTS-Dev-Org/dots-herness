// Copyright (c) 2026 DOTS
// Browse Hugging Face by task and turn any file or repository into a local model.

import Foundation

/// A Local models shelf. Text shelves list GGUF builds llama.cpp can serve;
/// media shelves list whatever the Hub has for that task, download-only.
public struct LocalModelCategory: Identifiable, Sendable, Hashable {
    public let id: String
    public let pipeline: String?
    public let search: String?
    public let runnable: Bool

    public static let all: [LocalModelCategory] = [
        LocalModelCategory(id: "chat", pipeline: "text-generation", search: nil, runnable: true),
        LocalModelCategory(id: "coding", pipeline: "text-generation", search: "coder", runnable: true),
        LocalModelCategory(id: "image", pipeline: "text-to-image", search: nil, runnable: false),
        LocalModelCategory(id: "design", pipeline: "image-to-image", search: nil, runnable: false),
        LocalModelCategory(id: "modeling", pipeline: "image-to-3d", search: nil, runnable: false),
        LocalModelCategory(id: "video", pipeline: "text-to-video", search: nil, runnable: false),
        LocalModelCategory(id: "audio", pipeline: "text-to-speech", search: nil, runnable: false),
    ]

    public static func named(_ id: String?) -> LocalModelCategory? { all.first { $0.id == id } }
}

public struct HubModel: Identifiable, Decodable, Sendable, Hashable {
    public let id: String
    public let downloads: Int?
    public let likes: Int?
    public let pipelineTag: String?
    public let createdAt: String?
    public let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case id, downloads, likes, tags, createdAt
        case pipelineTag = "pipeline_tag"
    }

    public var author: String { String(id.split(separator: "/").first ?? "") }
    public var name: String { String(id.split(separator: "/").last ?? Substring(id)) }
    public var pageURL: URL { URL(string: "https://huggingface.co/\(id)")! }
    public var category: String {
        LocalModelCategory.all.first { $0.pipeline == pipelineTag && $0.search == nil }?.id ?? "chat"
    }
}

public struct HubFile: Identifiable, Sendable, Hashable {
    public let path: String
    public let size: Int64
    public let sha256: String?
    public var id: String { path }
}

public enum HuggingFaceHub {
    static let host = "https://huggingface.co"
    private static let weightExtensions: Set<String> = ["gguf", "safetensors", "bin", "ckpt", "pth", "pt", "onnx"]

    /// Most downloaded repositories for a shelf (or GGUF overall) matching `query`.
    public static func searchURL(_ category: LocalModelCategory?, query: String, limit: Int = 30) -> URL {
        var parts = URLComponents(string: "\(host)/api/models")!
        parts.queryItems = filters(category, query: query, gguf: "filter") + [
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return parts.url!
    }

    /// The same listing on huggingface.co.
    public static func webURL(_ category: LocalModelCategory?, query: String) -> URL {
        var parts = URLComponents(string: "\(host)/models")!
        parts.queryItems = filters(category, query: query, gguf: "library") + [URLQueryItem(name: "sort", value: "downloads")]
        return parts.url!
    }

    private static func filters(_ category: LocalModelCategory?, query: String, gguf: String) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if category?.runnable ?? true { items.append(URLQueryItem(name: gguf, value: "gguf")) }
        if let pipeline = category?.pipeline { items.append(URLQueryItem(name: "pipeline_tag", value: pipeline)) }
        let search = [category?.search, query.trimmingCharacters(in: .whitespaces)].compactMap { $0 }.filter { !$0.isEmpty }
        if !search.isEmpty { items.append(URLQueryItem(name: "search", value: search.joined(separator: " "))) }
        return items
    }

    public static func search(_ category: LocalModelCategory?, query: String) async throws -> [HubModel] {
        try JSONDecoder().decode([HubModel].self, from: try await get(searchURL(category, query: query)))
    }

    /// Every file in the repository, folders flattened.
    public static func tree(_ repo: String) async throws -> [HubFile] {
        let data = try await get(URL(string: "\(host)/api/models/\(repo)/tree/main?recursive=true")!)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard row["type"] as? String == "file", let path = row["path"] as? String else { return nil }
            return HubFile(path: path, size: (row["size"] as? NSNumber)?.int64Value ?? 0,
                           sha256: (row["lfs"] as? [String: Any])?["oid"] as? String)
        }
    }

    /// Model weights only, GGUF first, then smallest: the files worth picking one of.
    public static func weights(_ files: [HubFile]) -> [HubFile] {
        files.filter { weightExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
            .sorted { ($0.path.hasSuffix(".gguf") ? 0 : 1, $0.size) < ($1.path.hasSuffix(".gguf") ? 0 : 1, $1.size) }
    }

    /// A local model for one file of `repo`, or for the whole repository when `file` is nil.
    public static func spec(repo: String, file: HubFile?, category: String, total: Int64 = 0) -> LocalModelSpec {
        let folder = repo.replacingOccurrences(of: "/", with: "--")
        let author = String(repo.split(separator: "/").first ?? "")
        guard let file else {
            return LocalModelSpec(
                id: "hf:\(repo)", name: String(repo.split(separator: "/").last ?? Substring(repo)), family: author,
                sizeLabel: LocalModelCatalog.prettyBytes(total), context: 0, filename: folder,
                url: URL(string: "\(host)/\(repo)")!, bytes: total, notes: repo, engine: .repo, repo: repo, category: category
            )
        }
        let lower = file.path.lowercased()
        let runnable = lower.hasSuffix(".gguf") && !lower.contains("mmproj") && LocalModelCategory.named(category)?.runnable != false
        return LocalModelSpec(
            id: "hf:\(repo)/\(file.path)",
            name: URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent,
            family: author,
            sizeLabel: LocalModelCatalog.prettyBytes(file.size),
            // ponytail: the trained context lives in the GGUF; llama-server reports the served one.
            context: 32_768,
            filename: "hub/\(folder)/\(file.path)",
            url: URL(string: "\(host)/\(repo)/resolve/main/\(file.path)")!,
            bytes: file.size,
            notes: repo,
            engine: runnable ? .llama : .file,
            sha256: file.sha256,
            repo: repo,
            // Weights plus KV cache and runtime overhead, roughly.
            minMemoryGB: runnable ? Int((Double(file.size) * 1.2 / 1_073_741_824).rounded(.up)) : 0,
            category: category
        )
    }

    private static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RouterError(AppCopy.format("download.failed", status)) }
        return data
    }
}
