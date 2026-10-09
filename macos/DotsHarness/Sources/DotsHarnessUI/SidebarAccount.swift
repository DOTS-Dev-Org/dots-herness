// Copyright (c) 2026 DOTS
// Sidebar account menu and badge.

import AppKit
import SwiftUI
import DotsHarnessCore
import HarnessPluginKit
import PluginRuntime

struct AccountMenuPopover: View {
    let account: AccountIdentity
    @ObservedObject var model: AppModel
    let onSettings: () -> Void
    let onSignOut: () -> Void

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

            AccountLimitsSection(router: model.router)

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
}

/// Per-account rate limits, inline in either footer popover. No sign-in nag:
/// accounts that report no endpoint (API keys) just say there is no limit info.
struct AccountLimitsSection: View {
    @ObservedObject var router: RouterController

    private var activeAccounts: [RouterConnection] { router.connections.filter(\.active) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppCopy.text("sidebar.usage"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if activeAccounts.isEmpty {
                Text(AppCopy.text("usage.noLimitInfo"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeAccounts) { connection in
                    AccountLimitRow(connection: connection, router: router)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ProviderLogoView(name: connection.name, providerID: connection.provider, size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let email = connection.email {
                        Text(email)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let remaining {
                    let used = min(max(1 - remaining, 0), 1)
                    Text("\(Int((used * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
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

                HStack(spacing: 6) {
                    Text(AppCopy.format("router.quotaRemaining", Int((remaining * 100).rounded())))
                    Spacer(minLength: 0)
                    if let reset = snapshot?.resetsAt ?? fallbackReset {
                        Text(resetLabel(reset))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                let known = windows.compactMap { window in
                    window.usedPercent.map { (window.kind, $0) }
                }
                if !known.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(known, id: \.0) { kind, percent in
                            Text("\(windowLabel(kind)) \(Int((percent * 100).rounded()))%")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
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

    private func resetLabel(_ date: Date) -> String {
        switch ClaudeUsageService.resetText(date) {
        case .relative(let text): return AppCopy.format("usage.resetsIn", text)
        case .weekday(let text): return AppCopy.format("usage.resetsOn", text)
        }
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
            .background(
                isHovered ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
