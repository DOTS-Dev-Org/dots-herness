// Copyright (c) 2026 DOTS
// Live Claude usage: the shared panel plus the sidebar dropdown that hosts it.

import SwiftUI
import DotsHarnessCore

/// Renders `router.claudeUsage`, which the router's app-wide poll keeps current.
struct ClaudeUsagePanel: View {
    @ObservedObject var router: RouterController

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch router.claudeUsage {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                caption("usage.loading")
            }
        case .failed(.noAccount):
            caption("usage.noLimitInfo")
        case .failed(.needsLogin):
            caption("usage.needLogin")
        case .failed(.network):
            caption("usage.loadFailed")
        case .loaded(let usage):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(usage.windows, id: \.kind) { UsageWindowRow(window: $0) }
                if let connection = router.connections.first(where: {
                    $0.active && $0.provider == "claude" && $0.authType == "oauth"
                }) {
                    ClaudeResetButton(connection: connection, resetsAvailable: usage.resetsAvailable, router: router)
                }
            }
        }
    }

    private func caption(_ key: String) -> some View {
        Text(AppCopy.text(key)).font(.caption).foregroundStyle(.secondary)
    }
}

struct UsageWindowRow: View {
    let window: ClaudeUsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(AppCopy.text(window.kind == .fiveHour ? "usage.window5h" : "usage.windowWeek"))
                    .font(.caption.weight(.medium))
                Spacer()
                if let percent = window.usedPercent {
                    Text("\(Int((percent * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(usageHeatColor(percent))
                }
            }
            if let percent = window.usedPercent {
                ProgressView(value: min(max(percent, 0), 1)).tint(usageHeatColor(percent))
            }
            if let reset = window.resetsAt {
                Text(usageResetLabel(reset)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
