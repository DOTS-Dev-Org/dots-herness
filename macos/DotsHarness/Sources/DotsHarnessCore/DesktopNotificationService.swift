// Copyright (c) 2026 DOTS
// Native macOS notifications for completed assistant responses.

import Foundation
import UserNotifications

public final class DesktopNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    public override init() {
        super.init()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func showAssistantResponse(_ event: AssistantResponseEvent) {
        let content = UNMutableNotificationContent()
        content.title = "Dots Harness"
        content.subtitle = event.conversationTitle
        content.body = Self.preview(event.text)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "assistant-response-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private static func preview(_ text: String) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 240 ? String(compact.prefix(240)) + "…" : compact
    }
}
