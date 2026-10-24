// Copyright (c) 2026 DOTS
// Context-window ring for the composer and its breakdown popover.

import SwiftUI
import DotsHarnessCore

struct ContextRingButton: View {
    @Binding var isPresented: Bool
    let events: [AgentContextUsageEvent]
    let contextWindowForEvent: (AgentContextUsageEvent) -> Int?

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
                Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1.875)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(fraction > 0.9 ? Color.red : Color.primary.opacity(0.75),
                            style: StrokeStyle(lineWidth: 1.875, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 21, height: 21)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppCopy.text("usage.context.tooltip"))
        .help(AppCopy.text("usage.context.tooltip"))
        .inWindowPopover(isPresented: $isPresented, alignment: .trailing, width: 260) {
            ContextUsagePopover(events: events, contextWindowForEvent: contextWindowForEvent)
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

/// Minimal by default: fill, input/output, cache hit and reuse. Estimates and
/// cache diagnostics sit behind "Daha fazla göster".
struct ContextUsagePopover: View {
    let events: [AgentContextUsageEvent]
    let contextWindowForEvent: (AgentContextUsageEvent) -> Int?
    @State private var showsDetails = false

    private var latest: AgentContextUsageEvent? {
        events.sorted { $0.timestamp < $1.timestamp }.last(where: { $0.requestKind == .main })
    }

    private var window: Int {
        guard let latest else { return 0 }
        return contextWindowForEvent(latest) ?? latest.contextWindowTokens ?? 0
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

    private var detailLines: [String] {
        var lines: [String] = []
        // The headline hit rate covers the whole conversation; the latest
        // request's own rate shows whether the cache just broke.
        if let rate = latest?.measuredCacheHitRate {
            lines.append(AppCopy.format("usage.context.cacheHitLatest", percent(rate)))
        }
        if cacheWrite > 0 {
            lines.append(AppCopy.format("usage.context.cacheWrite", compact(cacheWrite)))
        }
        if reuseSummary.freshInputTokens > 0 {
            lines.append(AppCopy.format("usage.context.cacheFreshInput", compact(reuseSummary.freshInputTokens)))
        }
        if let milliseconds = reuseSummary.averageLatencyMilliseconds {
            lines.append(AppCopy.format("usage.context.cacheLatency", "\(milliseconds)"))
        }
        if reuseSummary.averageFirstTokenMilliseconds != nil || reuseSummary.averagePrepareMilliseconds != nil {
            // Abbreviations, not prose: the same in every language.
            lines.append("TTFT \(reuseSummary.averageFirstTokenMilliseconds.map { "\($0) ms" } ?? "—") · prep \(reuseSummary.averagePrepareMilliseconds.map { "\($0) ms" } ?? "—")")
        }
        if let cpu = latest?.cpu {
            let stages = cpu.prepareStages
            let labels = [
                ("prompt", stages.filter { $0.key.hasPrefix("prompt_") }.values.reduce(0, +)),
                ("activity", stages["prompt_activity"] ?? 0),
                ("rules", stages["prompt_rules"] ?? 0),
                ("memory", stages["prompt_memory"] ?? 0),
                ("catalog", stages["tool_catalog"] ?? 0),
                ("epoch", stages["cache_epoch"] ?? 0),
            ]
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1) ms" }
            if !labels.isEmpty { lines.append("CPU · " + labels.joined(separator: " · ")) }

            let hits = cpu.prepareCacheHits ?? [:]
            let misses = cpu.prepareCacheMisses ?? [:]
            let cacheNames = Set(hits.keys).union(misses.keys).sorted()
            if !cacheNames.isEmpty {
                lines.append("prep cache · " + cacheNames.map {
                    "\($0) H\(hits[$0, default: 0]) M\(misses[$0, default: 0])"
                }.joined(separator: " · "))
            }
        }
        if let loss = reuseSummary.lostTokensByReason.max(by: { $0.value < $1.value }) {
            lines.append(AppCopy.format("usage.context.cacheLoss", loss.key, compact(loss.value)))
        }
        if cacheSummary.unknownRequestCount > 0 {
            lines.append("\(AppCopy.text("usage.context.notReported")): \(cacheSummary.unknownRequestCount) / \(cacheSummary.requestCount) · \(compact(cacheSummary.unknownInputTokens)) \(AppCopy.text("usage.context.tokens"))")
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if latest != nil {
                usageRows
                cacheRows
                if !rows.isEmpty || !detailLines.isEmpty {
                    Button { showsDetails.toggle() } label: {
                        Label(AppCopy.text("sidebar.showMore"), systemImage: showsDetails ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { ($0 ? NSCursor.pointingHand : NSCursor.arrow).set() }
                    if showsDetails { detailRows }
                }
            }
        }
        .padding(14)
    }

    private var header: some View {
        let used = latest?.contextTokens ?? 0
        let estimated = latest.map { $0.totalInputTokens == 0 || $0.outputTokens == 0 } ?? true
        let usedLabel = estimated ? "≈\(compact(used))" : compact(used)
        return VStack(alignment: .leading, spacing: 6) {
            Text(AppCopy.text("usage.context.latestRequest"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let modelID = latest?.model.split(separator: "/").last.map(String.init) {
                Text(modelID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if window > 0 {
                Text("\(usedLabel) / \(exact(window)) (\(percent(Double(used) / Double(window))))")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                ProgressView(value: min(1, Double(used) / Double(window)))
                    .tint(.primary.opacity(0.75))
            } else {
                Text(used > 0 ? usedLabel : "—")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private var usageRows: some View {
        let input = latest?.contextInputTokens ?? 0
        let output = latest?.outputTokens ?? 0
        let measured = (latest?.totalInputTokens ?? 0) > 0
        return VStack(alignment: .leading, spacing: 5) {
            row(AppCopy.text(measured ? "usage.context.input" : "usage.context.estimatedInput"),
                measured ? compact(input) : "≈\(compact(input))")
            row(AppCopy.text("usage.context.output"),
                output > 0 ? compact(output) : AppCopy.text("usage.context.notReported"))
        }
    }

    private var cacheRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(AppCopy.text("usage.context.cacheHit"),
                cacheEligible > 0 ? percent(Double(cacheHit) / Double(cacheEligible)) : AppCopy.text("usage.context.notReported"))
            // Exact reuse needs a proven cache boundary; routes that cannot prove
            // one (no measured request) would only show an empty row.
            if reuseSummary.measuredRequests > 0 {
                row(AppCopy.text("usage.context.cacheReuse"),
                    reuseSummary.reuseRate.map(percent) ?? AppCopy.text("usage.context.notReported"))
                Text(AppCopy.format("usage.context.cacheCoverage", reuseSummary.coverage.map(percent) ?? "—",
                    "\(reuseSummary.measuredRequests)", "\(reuseSummary.candidateRequests)"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !rows.isEmpty {
                Text(AppCopy.text("usage.context.estimatedBreakdown")).fontWeight(.medium)
                ForEach(rows) { item in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 8, height: 8)
                        Text(item.title)
                        Spacer(minLength: 8)
                        Text("≈\(compact(item.tokens))")
                        Text(percent(breakdownTotal > 0 ? Double(item.tokens) / Double(breakdownTotal) : 0))
                            .frame(width: 40, alignment: .trailing)
                    }
                    .monospacedDigit()
                }
            }
            ForEach(detailLines, id: \.self) { Text($0) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private func compact(_ n: Int) -> String {
        // Keep token suffixes stable across locales. Foundation's Turkish
        // compact notation uses "B" for bin, which many users read as billion.
        guard n >= 1_000 else { return "\(n)" }
        let divisor: Double
        let suffix: String
        if n >= 1_000_000_000 {
            divisor = 1_000_000_000
            suffix = "B"
        } else if n >= 1_000_000 {
            divisor = 1_000_000
            suffix = "M"
        } else {
            divisor = 1_000
            suffix = "K"
        }
        let value = String(format: "%.1f", Double(n) / divisor)
        return "\(value)\(suffix)"
    }

    private func exact(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
    }

    private func percent(_ f: Double) -> String {
        f.formatted(.percent.precision(.fractionLength(0...2)))
    }
}
