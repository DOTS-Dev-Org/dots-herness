// Copyright (c) 2026 DOTS
// Shared account-usage summary and compact ring for the avatar menu.

import SwiftUI
import DotsHarnessCore

struct SidebarUsageBadge: View {
    @ObservedObject var router: RouterController
    @State private var isLimitsPresented = false

    /// Current short-window usage across subscription accounts. The weekly
    /// window remains available in the expanded per-account detail.
    private var displayedUsedPercent: Double? { accountUsageUsedFraction(router) }

    private var resetsAt: Date? {
        if case .loaded(let usage) = router.claudeUsage {
            if let reset = usage.windows.compactMap(\.resetsAt).min() { return reset }
        }
        return router.accountUsage.values.compactMap(\.resetsAt).min()
    }

    private var isLoading: Bool {
        if case .loading = router.claudeUsage { return displayedUsedPercent == nil }
        return false
    }

    var body: some View {
        Button {
            isLimitsPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                gauge

                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(percentLabel)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint)
                        .frame(width: 30, alignment: .leading)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .popover(isPresented: $isLimitsPresented, attachmentAnchor: .rect(.bounds)) {
            AccountLimitsSection(router: router)
                .padding(.bottom, 4)
                .frame(width: 300)
        }
    }

    @ViewBuilder
    private var gauge: some View {
        UsageRing(usedPercent: displayedUsedPercent)
        .frame(width: 14, height: 14)
    }

    private var percentLabel: String {
        guard let percent = displayedUsedPercent else { return "—" }
        return "\(Int((percent * 100).rounded()))%"
    }

    private var tint: Color {
        guard let percent = displayedUsedPercent else { return .secondary }
        return usageHeatColor(percent)
    }

    private var helpText: String {
        guard let percent = displayedUsedPercent else {
            switch router.claudeUsage {
            case .failed(.needsLogin): return AppCopy.text("usage.needLogin")
            case .loading: return AppCopy.text("usage.loading")
            default: return AppCopy.text("usage.noLimitInfo")
            }
        }
        var text = "\(Int((percent * 100).rounded()))%"
        guard let reset = resetsAt else { return text }
        switch ClaudeUsageService.resetText(reset) {
        case .relative(let value): text += " · " + AppCopy.format("usage.resetsIn", value)
        case .weekday(let value): text += " · " + AppCopy.format("usage.resetsOn", value)
        }
        return text
    }
}

@MainActor
func accountUsageUsedFraction(_ router: RouterController) -> Double? {
    if case .loaded(let usage) = router.claudeUsage {
        if let current = usage.windows.first(where: { $0.kind == .fiveHour })?.usedPercent { return current }
        if let percent = usage.worstUsedPercent { return percent }
    }
    return router.accountUsage.values
        .compactMap { snapshot in
            snapshot.windows.first(where: { $0.kind == .fiveHour })?.usedPercent
                ?? snapshot.remainingFraction.map { min(max(1 - $0, 0), 1) }
        }
        .max()
}

struct UsageRing: View {
    let usedPercent: Double?

    var body: some View {
        let clamped = min(max(usedPercent ?? 0, 0), 1)
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(usedPercent.map(usageHeatColor) ?? Color.secondary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.2), value: clamped)
    }
}
