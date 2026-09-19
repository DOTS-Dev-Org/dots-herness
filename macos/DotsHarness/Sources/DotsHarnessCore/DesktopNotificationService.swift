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

    public func showRunSummary(_ event: RunSummaryEvent) {
        // The user stopped it themselves; nothing to tell them.
        guard event.outcome != .stopped else { return }
        let content = UNMutableNotificationContent()
        content.subtitle = event.conversationTitle
        if event.outcome == .failed {
            content.title = AppCopy.text("tasks.notification.failed")
            content.body = Self.preview(event.failureMessage ?? event.summary.cleanupNote)
        } else {
            content.title = AppCopy.text("conversation.runSummary")
            content.body = AppCopy.format(
                "conversation.filesSummary",
                event.summary.addedCount,
                event.summary.modifiedCount,
                event.summary.deletedCount
            ) + " · " + event.summary.cleanupNote
        }
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "run-summary-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    /// A chat is waiting on the user: approval, an answer, or a download.
    public func showAttention(_ event: RunAttentionEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.kind == .question ? AppCopy.text("ask.title") : AppCopy.text("plan.waitingApproval")
        content.subtitle = event.conversationTitle
        content.body = Self.preview(event.detail)
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "run-attention-\(event.conversationID)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    public func showScheduledTask(_ task: ScheduledTask, result: TaskScheduler.RunResult) {
        let content = UNMutableNotificationContent()
        content.title = AppCopy.text("tasks.notification.title")
        content.subtitle = task.name
        let status = result.ok
            ? AppCopy.text("tasks.notification.completed")
            : AppCopy.text("tasks.notification.failed")
        let fallback = result.fallbackUsed ? " · \(AppCopy.text("tasks.notification.fallback"))" : ""
        content.body = "\(status)\(fallback): \(Self.preview(result.message))"
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "scheduled-task-\(task.id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    public func showConnectionChange(_ transition: ConnectionTransition) {
        let previous = transition.previousConnectionLabel ?? AppCopy.text("router.unknown")
        let current = transition.currentConnectionLabel ?? AppCopy.text("router.unknown")
        let body: String
        switch transition.action {
        case "removed" where transition.cleanupStatus == "verified":
            body = AppCopy.text("conversation.connectionRemoved")
        case "removed" where transition.cleanupStatus == "failed":
            body = AppCopy.text("conversation.connectionCleanupFailed")
        case "added" where transition.previousConnectionLabel == nil:
            body = AppCopy.format("conversation.connectionAdded", current)
        case "selected":
            body = AppCopy.format("conversation.connectionSelected", current)
        default:
            body = AppCopy.format("conversation.connectionSummary", previous, current)
                + " · " + AppCopy.format("conversation.connectionPreserved", previous)
        }
        let content = UNMutableNotificationContent()
        content.title = AppCopy.text("conversation.connectionChanged")
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "connection-changed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    private static func preview(_ text: String) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 240 ? String(compact.prefix(240)) + "…" : compact
    }
}
