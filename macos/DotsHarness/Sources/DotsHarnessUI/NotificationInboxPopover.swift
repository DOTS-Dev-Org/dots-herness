// Copyright (c) 2026 DOTS
// In-app notification card opened from the sidebar bell.

import SwiftUI
import DotsHarnessCore

struct NotificationInboxPopover: View {
    @ObservedObject var inbox: NotificationInbox
    let onSelect: (InboxNotification) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(AppCopy.text("notifications.title"))
                    .font(.system(size: 15, weight: .semibold))

                if inbox.unreadCount > 0 {
                    Text("\(inbox.unreadCount)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                Spacer(minLength: 8)

                if inbox.unreadCount > 0 {
                    Button(AppCopy.text("notifications.markAllRead")) {
                        inbox.markAllRead()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help(AppCopy.text("notifications.markAllRead"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.7)

            if inbox.items.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 5) {
                        ForEach(inbox.items) { item in
                            notificationRow(item)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)

                Divider().opacity(0.7)

                HStack {
                    Text(AppCopy.format("notifications.itemCount", inbox.items.count))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button(role: .destructive) {
                        inbox.clear()
                    } label: {
                        Label(AppCopy.text("notifications.clearAll"), systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help(AppCopy.text("notifications.clearAll"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .frame(width: 340)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.secondary)
            Text(AppCopy.text("notifications.emptyTitle"))
                .font(.system(size: 13, weight: .medium))
            Text(AppCopy.text("notifications.emptyBody"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
    }

    private func notificationRow(_ item: InboxNotification) -> some View {
        Button {
            onSelect(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(item.kind.tint)
                    .frame(width: 28, height: 28)
                    .background(item.kind.tint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: item.isRead ? .medium : .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if !item.isRead {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)
                        }
                    }

                    Text(item.createdAt, style: .relative)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.9))
                            .lineLimit(2)
                    }

                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.primary.opacity(0.82))
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                item.isRead ? Color.clear : Color.accentColor.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text([item.title, item.subtitle, item.detail].filter { !$0.isEmpty }.joined(separator: ", ")))
    }
}

private extension InboxNotification.Kind {
    var symbol: String {
        switch self {
        case .question: "questionmark.bubble.fill"
        case .approval: "hand.raised.fill"
        case .visionInstall: "arrow.down.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .scheduledTask: "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .question, .approval, .visionInstall, .conflict: .orange
        case .completed, .scheduledTask: .green
        case .failed: .red
        }
    }
}
