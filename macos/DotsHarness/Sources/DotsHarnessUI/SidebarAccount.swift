// Copyright (c) 2026 DOTS
// Sidebar account menu and badge.

import AppKit
import SwiftUI
import DotsHarnessCore
import HarnessPluginKit
import PluginRuntime

struct AccountMenuPopover: View {
    let account: AccountIdentity
    @ObservedObject var router: RouterController
    let onSettings: () -> Void
    let onSignOut: () -> Void
    @State private var isUsageExpanded = false
    @State private var isUsageHovered = false

    private var usagePercent: Double? { accountUsageUsedFraction(router) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AccountBadge(initials: account.initials, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)

                    Text(account.isSignedIn ? "Plus" : AppCopy.text("sidebar.signOut"))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()
                .opacity(0.7)

            usageDisclosure

            Divider()
                .opacity(0.7)

            VStack(spacing: 2) {
                AccountMenuRow(
                    title: AppCopy.text("sidebar.settings"),
                    systemImage: "gearshape",
                    shortcut: "⌘,",
                    action: onSettings
                )

                Divider()
                    .padding(.vertical, 2)

                AccountMenuRow(
                    title: AppCopy.text("sidebar.signOut"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isDestructive: true,
                    role: .destructive,
                    action: onSignOut
                )
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity)
    }

    private var usageDisclosure: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isUsageExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gauge")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 22)

                    Text(AppCopy.text("sidebar.usage"))
                        .font(.system(size: 13, weight: .regular))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    UsageRing(usedPercent: usagePercent)
                        .frame(width: 15, height: 15)

                    Text(usagePercent.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(usagePercent.map(usageHeatColor) ?? Color.secondary)
                        .frame(minWidth: 28, alignment: .trailing)

                    Image(systemName: isUsageExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
                .background(
                    isUsageHovered ? Color.primary.opacity(0.09) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isUsageHovered = $0 }
            .accessibilityLabel(AppCopy.text("sidebar.usage"))

            if isUsageExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    AccountLimitsSection(router: router, compact: true)
                }
                .frame(maxHeight: 320)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

/// Per-account limits for the expandable avatar section. Accounts without a
/// usage endpoint (such as API keys) simply report that no limit is available.
struct AccountLimitsSection: View {
    @ObservedObject var router: RouterController
    var compact = false

    private var activeAccounts: [RouterConnection] { router.connections.filter(\.active) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            if activeAccounts.isEmpty {
                Text(AppCopy.text("usage.noLimitInfo"))
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeAccounts) { connection in
                    AccountLimitRow(connection: connection, router: router, compact: compact)
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            Task { await router.refreshAccountUsage() }
        }
    }
}

/// One connected account: logo, name/email, active-window usage bar, and the
/// reported window chips for subscription accounts.
struct AccountLimitRow: View {
    let connection: RouterConnection
    @ObservedObject var router: RouterController
    var compact = false

    private var isClaudeSubscription: Bool {
        connection.provider == "claude" && connection.authType == "oauth"
    }

    private var snapshot: AccountUsageSnapshot? { router.accountUsage[connection.id] }

    /// The row summarizes the active 5-hour window. Weekly usage remains visible
    /// in its own chip; routing still uses the most constrained window.
    private var remaining: Double? {
        if let used = windows.first(where: { $0.kind == .fiveHour })?.usedPercent {
            return min(max(1 - used, 0), 1)
        }
        if let fraction = snapshot?.remainingFraction { return fraction }
        if snapshot == nil, isClaudeSubscription, case .loaded(let usage) = router.claudeUsage,
           let used = usage.worstUsedPercent { return min(max(1 - used, 0), 1) }
        return nil
    }

    /// True while the first refresh for this account has not landed yet.
    private var pending: Bool { snapshot == nil && !(isClaudeSubscription && isLoaded) }

    private var isLoaded: Bool {
        if case .loaded = router.claudeUsage { return true }
        return false
    }

    private var windows: [ClaudeUsageWindow] {
        if let windows = snapshot?.windows, !windows.isEmpty { return windows }
        if snapshot == nil, isClaudeSubscription, case .loaded(let usage) = router.claudeUsage {
            return usage.windows
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: compact ? 6 : 8) {
                ProviderLogoView(name: connection.name, providerID: connection.provider, size: compact ? 20 : 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.name)
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                        .lineLimit(1)
                    if let email = connection.email,
                       email.localizedCaseInsensitiveCompare(connection.name) != .orderedSame {
                        Text(email)
                            .font(.system(size: compact ? 9 : 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let remaining {
                    let used = min(max(1 - remaining, 0), 1)
                    Text("\(Int((used * 100).rounded()))%")
                        .font(.system(size: compact ? 11 : 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(usageHeatColor(used))
                } else if pending {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(AppCopy.text("usage.noLimitInfo"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let remaining {
                let used = min(max(1 - remaining, 0), 1)
                ProgressView(value: used)
                    .tint(usageHeatColor(used))
                    .scaleEffect(x: 1, y: compact ? 0.72 : 1, anchor: .center)

                HStack(spacing: 6) {
                    Text(AppCopy.format("router.quotaRemaining", Int((remaining * 100).rounded())))
                    Spacer(minLength: 0)
                    if let reset = snapshot?.resetsAt ?? fallbackReset {
                        Text(usageResetLabel(reset))
                    }
                }
                .font(.system(size: compact ? 9 : 10))
                .foregroundStyle(.secondary)

                let known = windows.compactMap { window in
                    window.usedPercent.map { (window.kind, $0) }
                }
                if !known.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(known, id: \.0) { kind, percent in
                            Text("\(windowLabel(kind)) \(Int((percent * 100).rounded()))%")
                                .font(.system(size: compact ? 9 : 10, weight: .medium))
                                .padding(.horizontal, compact ? 5 : 6)
                                .padding(.vertical, compact ? 1 : 2)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }
                }
            }
            if isClaudeSubscription {
                ClaudeResetButton(connection: connection, resetsAvailable: snapshot?.resetsAvailable, router: router)
            }
        }
    }

    private func windowLabel(_ kind: ClaudeUsageWindow.Kind) -> String {
        AppCopy.text(kind == .fiveHour ? "usage.window5h" : "usage.windowWeek")
    }

    private var fallbackReset: Date? {
        if let snapshot { return snapshot.resetsAt }
        guard isClaudeSubscription, case .loaded(let usage) = router.claudeUsage else { return nil }
        return usage.windows.compactMap(\.resetsAt).min()
    }
}

/// Shared limit heat: 0-25% green … 75%+ red, matching `ClaudeUsagePanel`.
func usageHeatColor(_ percent: Double) -> Color {
    switch ClaudeUsageService.heatLevel(percent) {
    case 0: return .green
    case 1: return .yellow
    case 2: return .orange
    default: return .red
    }
}

func usageResetLabel(_ date: Date) -> String {
    switch ClaudeUsageService.resetText(date) {
    case .relative(let text): return AppCopy.format("usage.resetsIn", text)
    case .weekday(let text): return AppCopy.format("usage.resetsOn", text)
    }
}

struct AccountMenuRow: View {
    let title: String
    let systemImage: String
    var trailingSystemImage: String? = nil
    var shortcut: String? = nil
    var isDestructive = false
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            AccountMenuRowLabel(
                title: title,
                systemImage: systemImage,
                trailingSystemImage: trailingSystemImage,
                shortcut: shortcut,
                isDestructive: isDestructive
            )
            .background(
                isHovered ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct AccountMenuRowLabel: View {
    let title: String
    let systemImage: String
    var trailingSystemImage: String? = nil
    var shortcut: String? = nil
    var isDestructive = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 22)

            Text(title)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)

            Spacer(minLength: 10)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isDestructive ? Color.red : Color.primary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
    }
}

struct AccountBadge: View {
    var initials: String
    var size: CGFloat = 22

    var body: some View {
        Text(initials)
            .font(.system(size: max(8, size * 0.43), weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(Color(red: 0.20, green: 0.72, blue: 0.55), in: Circle())
    }
}
