// Copyright (c) 2026 DOTS
// On-disk project library shared by the Media and Music studios.

import Foundation

public protocol StudioProject: Identifiable, Codable where ID == String {
    var updatedAt: Date { get set }
}

/// One folder per project under `root`: `project.json` plus an `assets` folder.
@MainActor
public class StudioProjectStore<Project: StudioProject>: ObservableObject {
    @Published public private(set) var projects: [Project] = []
    /// The project open in the editor, which takes over the Media section while it is set.
    @Published public var openProjectID: String?

    let root: URL
    private(set) var hasLoaded = false
    private let fallbackAssetExtension: String

    init(root: URL, fallbackAssetExtension: String) {
        self.root = root
        self.fallbackAssetExtension = fallbackAssetExtension
    }

    /// Reads every project from disk once; the views call it when the studio first appears.
    public func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        projects = folders.compactMap { read(Project.self, from: $0.appendingPathComponent("project.json")) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    public func save(_ project: Project) {
        var project = project
        project.updatedAt = Date()
        write(project, to: directory(for: project.id).appendingPathComponent("project.json"))
        projects.removeAll { $0.id == project.id }
        projects.insert(project, at: 0)
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: directory(for: id))
        projects.removeAll { $0.id == id }
        if openProjectID == id { openProjectID = nil }
    }

    public func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public func assetURL(projectID: String, name: String) -> URL {
        directory(for: projectID).appendingPathComponent("assets", isDirectory: true).appendingPathComponent(name)
    }

    /// Copies a file into the project so the project never depends on where it came from.
    public func importAsset(from source: URL, into projectID: String) throws -> String {
        let assets = directory(for: projectID).appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? fallbackAssetExtension : source.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        try FileManager.default.copyItem(at: source, to: assets.appendingPathComponent(name))
        return name
    }

    func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    func write<Value: Encodable>(_ value: Value, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
