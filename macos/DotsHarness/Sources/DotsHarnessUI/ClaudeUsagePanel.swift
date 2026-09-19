// Copyright (c) 2026 DOTS
// Live Claude usage: the shared panel plus the sidebar dropdown that hosts it.

import SwiftUI
import DotsHarnessCore

/// Renders `router.claudeUsage` and polls it every 60s while on screen.
/// No persistence; SwiftUI cancels the `.task` on disappear.
struct ClaudeUsagePanel: View {
    @ObservedObject var router: RouterController

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .task {
                while !Task.isCancelled {
                    await router.refreshClaudeUsage()
                    await router.refreshAccountUsage()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
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
                if let count = usage.resetsAvailable {
                    Text(AppCopy.format("usage.resetsAvailable", count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func caption(_ key: String) -> some View {
        Text(AppCopy.text(key)).font(.caption).foregroundStyle(.secondary)
    }
}

private struct UsageWindowRow: View {
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
                        .foregroundStyle(heatColor(percent))
                }
            }
            if let percent = window.usedPercent {
                ProgressView(value: min(max(percent, 0), 1)).tint(heatColor(percent))
            }
            if let reset = window.resetsAt {
                Text(resetLabel(reset)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func heatColor(_ percent: Double) -> Color {
        switch ClaudeUsageService.heatLevel(percent) {
        case 0: return .green
        case 1: return .yellow
        case 2: return .orange
        default: return .red
        }
    }

    private func resetLabel(_ date: Date) -> String {
        switch ClaudeUsageService.resetText(date) {
        case .relative(let text): return AppCopy.format("usage.resetsIn", text)
        case .weekday(let text): return AppCopy.format("usage.resetsOn", text)
        }
    }
}

/// Sidebar account-footer dropdown. Reproduces the sidebar's chevron/animation
/// pattern inline so it carries no dependency on `SidebarView` internals.
struct SidebarUsageDropdown: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { model.isUsageExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Text(AppCopy.text("sidebar.usage"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: model.isUsageExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 20)
                }
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.isUsageExpanded {
                ClaudeUsagePanel(router: model.router)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}
