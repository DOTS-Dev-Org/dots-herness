// Copyright (c) 2026 DOTS
// Context-window ring for the composer and its breakdown popover.

import SwiftUI
import DotsHarnessCore

struct ContextRingButton: View {
    let events: [AgentContextUsageEvent]
    let contextWindowForEvent: (AgentContextUsageEvent) -> Int?
    @State private var isPresented = false

    init(
        events: [AgentContextUsageEvent],
        contextWindowForEvent: @escaping (AgentContextUsageEvent) -> Int? = { $0.contextWindowTokens }
    ) {
        self.events = events
        self.contextWindowForEvent = contextWindowForEvent
    }

    private var latest: AgentContextUsageEvent? {
        events.sorted { $0.timestamp < $1.timestamp }.last(where: { $0.requestKind == .main })
    }

    private var latestWindow: Int? {
        guard let latest else { return nil }
        return contextWindowForEvent(latest) ?? latest.contextWindowTokens
    }

    private var fraction: Double {
        guard let latest, let window = latestWindow, window > 0 else { return 0 }
        return min(1, Double(latest.contextTokens) / Double(window))
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(fraction > 0.9 ? Color.red : Color.primary.opacity(0.75),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppCopy.text("usage.context.tooltip"))
        .help(AppCopy.text("usage.context.tooltip"))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ContextUsagePopover(events: events, contextWindowTokens: latestWindow)
        }
    }
}

extension AgentContextUsageEvent {
    /// Provider-reported input plus output when available. The fallback input
    /// estimate is deliberately kept separate from output accounting.
    var contextInputTokens: Int {
        totalInputTokens > 0 ? totalInputTokens : (inputComposition?.estimatedTotalTokens ?? 0)
    }

    var contextTokens: Int {
        contextInputTokens + max(0, outputTokens)
    }
}

private struct ContextUsagePopover: View {
    let events: [AgentContextUsageEvent]
    let contextWindowTokens: Int?

    private var latest: AgentContextUsageEvent? {
        events.sorted { $0.timestamp < $1.timestamp }.last(where: { $0.requestKind == .main })
    }

    private var cacheSummary: AgentContextCacheSummary { AgentContextCacheSummary(events: events) }
    private var cacheHit: Int { cacheSummary.cachedInputTokens }
    private var cacheEligible: Int { cacheSummary.measuredInputTokens }
    private var cacheWrite: Int { cacheSummary.cacheWriteTokens }
    private var reuseSummary: AgentCacheReuseSummary {
        guard let latest else { return .init(events: []) }
        return .init(events: events.filter { event in
            event.provider == latest.provider && event.api == latest.api && event.model == latest.model
                && event.cacheTrace?.accountFingerprint == latest.cacheTrace?.accountFingerprint
                && event.cacheTrace?.endpointFingerprint == latest.cacheTrace?.endpointFingerprint
        }, limit: nil)
    }

    private struct Row: Identifiable {
        let title: String
        let tokens: Int
        let color: Color
        var id: String { title }
    }

    private var rows: [Row] {
        guard let latest, let c = latest.inputComposition else { return [] }
        let values: [(String, Int, Color)] = [
            ("usage.context.conversation",
             c.conversationTokens + c.nativeToolCallTokens + c.mcpToolCallTokens
                + c.nativeToolResultTokens + c.mcpToolResultTokens, .blue),
            ("usage.context.toolDefinitions", c.nativeToolDefinitionTokens, .orange),
            ("usage.context.mcpDefinitions", c.mcpToolDefinitionTokens, .green),
            ("usage.context.systemPrompt", c.systemPromptTokens, .gray),
        ]
        let estimates = values.filter { $0.1 > 0 }
        let estimatedTotal = estimates.reduce(0) { $0 + $1.1 }
        let inputTotal = latest.contextInputTokens
        guard estimatedTotal > 0, inputTotal > 0 else { return [] }

        // Category values use a local tokenizer heuristic. When provider input
        // is available, allocate that measured total by the estimated category
        // proportions; otherwise keep the local estimates as-is.
        var allocated = 0
        return estimates.enumerated().compactMap { index, estimate in
            let remaining = max(0, inputTotal - allocated)
            let scaled = index == estimates.count - 1
                ? remaining
                : Int((Double(estimate.1) / Double(estimatedTotal) * Double(inputTotal)).rounded())
            let tokens = min(remaining, max(0, scaled))
            allocated += tokens
            guard tokens > 0 else { return nil }
            return Row(title: AppCopy.text(estimate.0), tokens: tokens, color: estimate.2)
        }
    }

    private var breakdownTotal: Int {
        rows.reduce(0) { $0 + $1.tokens }
    }

    var body: some View {
        let input = latest?.contextInputTokens ?? 0
        let output = latest?.outputTokens ?? 0
        let used = latest?.contextTokens ?? 0
        let window = contextWindowTokens ?? latest?.contextWindowTokens ?? 0
        let estimatedWindowUse = latest.map { $0.totalInputTokens == 0 || $0.outputTokens == 0 } ?? true
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(AppCopy.text("usage.context.latestRequest"))
                Spacer(minLength: 8)
                let usedLabel = estimatedWindowUse ? "≈\(compact(used))" : compact(used)
                if window > 0 {
                    Text("\(usedLabel) / \(exact(window)) (\(percent(Double(used) / Double(window))))")
                } else {
                    Text(used > 0 ? usedLabel : "—")
                }
            }
            .font(.callout)
            .monospacedDigit()

            if window > 0 {
                ProgressView(value: min(1, Double(used) / Double(window)))
                    .tint(.primary.opacity(0.75))
            }

            if latest != nil {
                HStack {
                    Text(AppCopy.text((latest?.totalInputTokens ?? 0) > 0
                        ? "usage.context.input" : "usage.context.estimatedInput"))
                    Spacer(minLength: 8)
                    let inputLabel = (latest?.totalInputTokens ?? 0) > 0 ? compact(input) : "≈\(compact(input))"
                    Text(inputLabel).foregroundStyle(.secondary)
                }
                .font(.caption)
                .monospacedDigit()

                HStack {
                    Text(AppCopy.text("usage.context.output"))
                    Spacer(minLength: 8)
                    Text(output > 0 ? compact(output) : AppCopy.text("usage.context.notReported"))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .monospacedDigit()
            }

            if !rows.isEmpty {
                Text(AppCopy.text("usage.context.estimatedBreakdown"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(row.color).frame(width: 10, height: 10)
                        Text(row.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("≈\(compact(row.tokens))").foregroundStyle(.secondary)
                        Text(percent(breakdownTotal > 0 ? Double(row.tokens) / Double(breakdownTotal) : 0))
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(AppCopy.text("usage.context.cacheHit"))
                    Spacer(minLength: 8)
                    if cacheEligible > 0 {
                        Text(percent(Double(cacheHit) / Double(cacheEligible)))
                            .monospacedDigit()
                    } else {
                        Text(AppCopy.text("usage.context.notReported")).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if cacheEligible > 0 {
                    ProgressView(value: min(1, Double(cacheHit) / Double(cacheEligible))).tint(.green)
                }
                if cacheWrite > 0 {
                    Text(AppCopy.format("usage.context.cacheWrite", compact(cacheWrite)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(AppCopy.text("usage.context.cacheReuse"))
                    Spacer(minLength: 8)
                    Text(reuseSummary.reuseRate.map(percent) ?? AppCopy.text("usage.context.notReported"))
                        .monospacedDigit()
                }
                .font(.caption)
                if reuseSummary.freshInputTokens > 0 {
                    Text(AppCopy.format("usage.context.cacheFreshInput", compact(reuseSummary.freshInputTokens)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(AppCopy.format("usage.context.cacheCoverage", reuseSummary.coverage.map(percent) ?? "—",
                    "\(reuseSummary.measuredRequests)", "\(reuseSummary.candidateRequests)"))
                    .font(.caption).foregroundStyle(.secondary)
                if let milliseconds = reuseSummary.averageLatencyMilliseconds {
                    Text(AppCopy.format("usage.context.cacheLatency", "\(milliseconds)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if reuseSummary.averageFirstTokenMilliseconds != nil || reuseSummary.averagePrepareMilliseconds != nil {
                    // Abbreviations, not prose: the same in every language.
                    Text("TTFT \(reuseSummary.averageFirstTokenMilliseconds.map { "\($0) ms" } ?? "—") · prep \(reuseSummary.averagePrepareMilliseconds.map { "\($0) ms" } ?? "—")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let loss = reuseSummary.lostTokensByReason.max(by: { $0.value < $1.value }) {
                    Text(AppCopy.format("usage.context.cacheLoss", loss.key, compact(loss.value)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if cacheSummary.unknownRequestCount > 0 {
                    Text("\(AppCopy.text("usage.context.notReported")): \(cacheSummary.unknownRequestCount) / \(cacheSummary.requestCount) · \(compact(cacheSummary.unknownInputTokens)) \(AppCopy.text("usage.context.tokens"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private func exact(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
    }

    private func percent(_ f: Double) -> String {
        f.formatted(.percent.precision(.fractionLength(0...2)))
    }
}
