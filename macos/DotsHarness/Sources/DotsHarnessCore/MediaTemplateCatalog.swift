// Copyright (c) 2026 DOTS

import Foundation

private struct MediaTemplateCatalogManifest: Decodable, Sendable {
    var version: Int
    var templates: [MediaTemplateCatalogItem]
}

private struct MediaTemplateCatalogItem: Decodable, Sendable {
    var id: String
    var category: String
    var presetId: String
    var titles: [String: String]
    var canvas: MediaCanvas
}

/// Loads templates from the public Cloudflare R2 catalog and keeps a last-good offline copy.
public enum MediaTemplateCatalogClient {
    public static let manifestURL = URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/assets/media-templates/manifest.json")!

    public static func load(cacheURL: URL, language: String) async -> [MediaTemplate] {
        var manifest: MediaTemplateCatalogManifest?
        var request = URLRequest(url: manifestURL, timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let decoded = try? JSONDecoder().decode(MediaTemplateCatalogManifest.self, from: data),
           isUsable(decoded) {
            manifest = decoded
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }

        if manifest == nil,
           let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(MediaTemplateCatalogManifest.self, from: data),
           isUsable(decoded) {
            manifest = decoded
        }

        guard let manifest, isUsable(manifest) else { return [] }
        let language = language.lowercased()
        return manifest.templates.map { item in
            let title = item.titles[language]
                ?? item.titles[language.split(separator: "-").first.map(String.init) ?? language]
                ?? item.titles["en"]
                ?? item.id
            let category = MediaTemplate.Category(rawValue: item.category) ?? .other
            return MediaTemplate(id: item.id, category: category, displayTitle: title) { item.canvas }
        }
    }

    private static func isUsable(_ manifest: MediaTemplateCatalogManifest) -> Bool {
        manifest.version == 1 && !manifest.templates.isEmpty && manifest.templates.allSatisfy {
            !$0.id.isEmpty && $0.canvas.width > 0 && $0.canvas.height > 0
        }
    }
}
