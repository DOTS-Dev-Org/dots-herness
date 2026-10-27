// Copyright (c) 2026 DOTS
// Routes agent events into the native notifications and the in-app inbox.

import Foundation

extension AppModel {
    func receiveAssistantResponse(_ event: AssistantResponseEvent) {
        desktopNotifications.showAssistantResponse(event)
        let conversation = bridge.conversations.first { $0.id == event.conversationID }
        notificationInbox.append(InboxNotification(
            kind: .completed,
            title: AppCopy.text("notifications.responseReady"),
            subtitle: event.conversationTitle,
            detail: event.text,
            conversationID: event.conversationID.isEmpty ? nil : event.conversationID,
            conversationPath: conversation?.cwd
        ))
    }

    func receiveRunSummary(_ event: RunSummaryEvent) {
        desktopNotifications.showRunSummary(event)
        // Successful responses are already recorded through
        // `AssistantResponseEvent` (also used by media requests). Keep run
        // summaries here only when the run failed.
        guard event.outcome == .failed else { return }

        let detail = event.failureMessage ?? event.summary.cleanupNote
        let conversation = bridge.conversations.first { $0.id == event.conversationID }
        notificationInbox.append(InboxNotification(
            kind: .failed,
            title: AppCopy.text("notifications.operationFailed"),
            subtitle: event.conversationTitle,
            detail: detail,
            conversationID: event.conversationID.isEmpty ? nil : event.conversationID,
            conversationPath: conversation?.cwd
        ))
    }

    func receiveAttention(_ event: RunAttentionEvent) {
        let kind: InboxNotification.Kind
        let title: String
        switch event.kind {
        case .question:
            kind = .question
            title = AppCopy.text("notifications.question")
        case .approval:
            kind = .approval
            title = AppCopy.text("plan.waitingApproval")
        case .visionInstall:
            kind = .visionInstall
            title = AppCopy.text("notifications.actionRequired")
        case .conflict:
            kind = .conflict
            title = AppCopy.text("notifications.actionRequired")
        }

        let question = event.kind == .question
            ? bridge.pendingQuestions.first(where: { $0.conversationID == event.conversationID })
            : nil
        let detail = question?.questions.map(\.prompt).joined(separator: " · ") ?? event.detail
        let conversation = bridge.conversations.first { $0.id == event.conversationID }
        notificationInbox.append(InboxNotification(
            kind: kind,
            title: title,
            subtitle: event.conversationTitle,
            detail: detail,
            conversationID: event.conversationID,
            conversationPath: conversation?.cwd
        ))

        desktopNotifications.showAttention(event)
    }

    func receiveScheduledTask(_ task: ScheduledTask, result: TaskScheduler.RunResult) {
        desktopNotifications.showScheduledTask(task, result: result)
        let status = result.ok
            ? AppCopy.text("tasks.notification.completed")
            : AppCopy.text("tasks.notification.failed")
        let fallback = result.fallbackUsed ? " · \(AppCopy.text("tasks.notification.fallback"))" : ""
        notificationInbox.append(InboxNotification(
            kind: .scheduledTask,
            title: AppCopy.text("tasks.notification.title"),
            subtitle: task.name,
            detail: "\(status)\(fallback): \(result.message)"
        ))
    }
}
