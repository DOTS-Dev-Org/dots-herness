// Copyright (c) 2026 DOTS
// Media community: canvases other people shared, read from the public feed.

import Foundation

public struct MediaCommunityPost: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var author: String
    public var category: String
    public var likes: Int
    public var canvas: MediaCanvas
}

extension MediaCanvas {
    /// The canvas as it travels to and from the community: fresh ids, no local files, no editing notes.
    /// ponytail: image and video layers arrive as placeholders; upload assets to R2 when shares need them.
    public func communityCopy() -> MediaCanvas {
        var copy = self
        copy.id = UUID().uuidString
        copy.x = 0
        copy.y = 0
        copy.parentID = nil
        copy.layers = layers.filter { !$0.comment }.map { layer in
            var layer = layer
            layer.id = UUID().uuidString
            layer.assetName = nil
            return layer
        }
        return copy
    }
}

@MainActor
public final class MediaCommunityClient: ObservableObject {
    @Published public private(set) var posts: [MediaCommunityPost] = []
    @Published public private(set) var isLoading = false

    public let session: MarketplaceSession
    private let cacheURL: URL

    public init(session: MarketplaceSession, cacheURL: URL) {
        self.session = session
        self.cacheURL = cacheURL
        if let data = try? Data(contentsOf: cacheURL) { posts = Self.decodeFeed(data) }
    }

    /// One unreadable post is dropped instead of emptying the feed.
    static func decodeFeed(_ data: Data) -> [MediaCommunityPost] {
        struct Slot: Decodable {
            var post: MediaCommunityPost?
            init(from decoder: Decoder) { post = try? MediaCommunityPost(from: decoder) }
        }
        struct Feed: Decodable { var posts: [Slot] }
        let found = (try? JSONDecoder().decode(Feed.self, from: data))?.posts.compactMap(\.post) ?? []
        return found.filter { $0.canvas.width > 0 && $0.canvas.height > 0 }.map { post in
            var post = post
            post.canvas = post.canvas.communityCopy()
            return post
        }
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Read from the API host: the dots.net.tr/harness route does not reach the worker.
        var request = URLRequest(
            url: session.apiBase.appendingPathComponent("harness/media-community.json"), timeoutInterval: 30
        )
        request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        posts = Self.decodeFeed(data)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Sends a canvas for review; it joins the feed once an admin approves it.
    public func share(_ canvas: MediaCanvas, title: String, category: MediaTemplate.Category) async throws {
        struct Upload: Encodable {
            var title: String
            var category: String
            var canvas: MediaCanvas
        }
        let body = try JSONEncoder().encode(
            Upload(title: String(title.prefix(80)), category: category.rawValue, canvas: canvas.communityCopy())
        )
        try await send(path: "api/media/community", body: body)
    }

    /// Counts the like on the server when signed in; the saved list itself stays on this Mac.
    public func setLiked(_ liked: Bool, postID: String) async {
        guard session.isSignedIn,
              let body = try? JSONEncoder().encode(["liked": liked]),
              let data = try? await send(path: "api/media/community/\(postID)/like", body: body),
              let likes = (try? JSONDecoder().decode([String: Int].self, from: data))?["likes"],
              let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[index].likes = likes
    }

    @discardableResult
    private func send(path: String, body: Data) async throws -> Data {
        let (data, response) = try await session.authorizedData(
            path: path, method: "POST", body: body, contentType: "application/json"
        )
        guard (200..<300).contains(response.statusCode) else {
            throw MarketplaceSessionError.requestFailed(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
