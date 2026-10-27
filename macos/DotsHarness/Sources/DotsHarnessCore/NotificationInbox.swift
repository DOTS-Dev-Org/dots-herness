// Copyright (c) 2026 DOTS
// A small local inbox for attention and run-completion events.

import Combine
import Foundation

public struct InboxNotification: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case question
        case approval
        case visionInstall
        case conflict
        case completed
        case failed
        case scheduledTask
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let detail: String
    public let conversationID: String?
    public let conversationPath: String?
    public let createdAt: Date
    public var isRead: Bool

    public init(
        kind: Kind,
        title: String,
        subtitle: String = "",
        detail: String = "",
        conversationID: String? = nil,
        conversationPath: String? = nil,
        createdAt: Date = Date(),
        isRead: Bool = false
    ) {
        id = UUID().uuidString
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.detail = Self.preview(detail)
        self.conversationID = conversationID
        self.conversationPath = conversationPath
        self.createdAt = createdAt
        self.isRead = isRead
    }

    private static func preview(_ text: String) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 240 ? String(compact.prefix(240)) + "…" : compact
    }
}

@MainActor
public final class NotificationInbox: ObservableObject {
    @Published public private(set) var items: [InboxNotification]

    public var unreadCount: Int {
        items.reduce(into: 0) { count, item in
            if !item.isRead { count += 1 }
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "herness.notificationInbox.v1"
    private let maximumItemCount = 100

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([InboxNotification].self, from: data) {
            items = Array(saved.sorted { $0.createdAt > $1.createdAt }.prefix(maximumItemCount))
        } else {
            items = []
        }
    }

    public func append(_ item: InboxNotification) {
        items.insert(item, at: 0)
        if items.count > maximumItemCount {
            items.removeLast(items.count - maximumItemCount)
        }
        persist()
    }

    public func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isRead else { return }
        items[index].isRead = true
        persist()
    }

    public func markAllRead() {
        guard items.contains(where: { !$0.isRead }) else { return }
        for index in items.indices { items[index].isRead = true }
        persist()
    }

    public func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
