// Copyright (c) 2026 DOTS
// Automatic model selection.
//
// Premium models are scarce and slow; most turns in an agent loop are mechanical
// (read a file, apply an edit, report a tool result). So the router splits a task
// into two roles and pays for capability only where it changes the outcome:
//
//   planner — opens a task, or the user asked to design / review / diagnose.
//             Best available model, highest effort it supports.
//   worker  — continues an already-planned task, usually right after a tool
//             result. Cheapest model that can still hold the thread, low effort.
//
// The decision is a pure function of the conversation and the connected models:
// no extra network round-trip, so routing never costs a request of its own.

import Foundation

public enum ModelTier: String, Codable, Sendable, CaseIterable, Comparable {
    case light
    case standard
    case premium

    private var rank: Int {
        switch self {
        case .light: return 0
        case .standard: return 1
        case .premium: return 2
        }
    }

    public static func < (lhs: ModelTier, rhs: ModelTier) -> Bool { lhs.rank < rhs.rank }

    /// Tier for a model the registry does not describe — live listings return ids
    /// we have never seen, and they still need to be routable.
    public static func inferred(from modelID: String) -> ModelTier {
        let id = modelID.lowercased()
        if id.contains("haiku") || id.contains("mini") || id.contains("nano")
            || id.contains("flash") || id.contains("lite") || id.contains("small") {
            return .light
        }
        if id.contains("opus") || id.contains("fable") || id.contains("mythos")
            || id.contains("-pro") || id.contains("ultra") || id.contains("max") {
            return .premium
        }
        return .standard
    }
}

public enum ModelRole: String, Sendable {
    case planner
    case worker
}

public struct ModelDecision: Sendable, Equatable {
    public var model: String
    public var effort: String
    public var role: String
    /// Short, user-facing reason. Surfaced in the picker so automatic routing is
    /// never a black box.
    public var reason: String
}

public enum ModelRouter {
    /// Sentinel stored as the selected model when automatic routing is on.
    public static let autoModelID = "auto"

    // Words that mean "think first". Matched on the latest user turn only —
    // earlier turns describe work already planned.
    private static let planningSignals = [
        "plan", "architect", "design", "refactor", "review", "audit", "debug",
        "diagnose", "root cause", "why", "compare", "trade-off", "tradeoff",
        "strategy", "migrate", "investigate", "explain",
        // Turkish, since the app ships localized
        "planla", "tasarla", "mimari", "incele", "araştır", "neden", "hata ayıkla",
        "karşılaştır", "gözden geçir", "çözümle",
    ]
    // Words that mean "just do it".
    private static let mechanicalSignals = [
        "rename", "typo", "format", "list", "print", "add a comment", "bump",
        "yeniden adlandır", "yazım", "biçimlendir", "listele",
    ]

    /// Picks the model and effort for the next request.
    /// - Parameters:
    ///   - messages: the conversation about to be sent.
    ///   - available: models from connected providers, in registry order
    ///     (authored best-first within a provider).
    ///   - tierOf: resolves a model's tier; falls back to `ModelTier.inferred`.
    ///   - excluding: providers already known to be unavailable this request
    ///     (rate limited, out of credit). Routing steps around them instead of
    ///     failing, which is the whole point of having several accounts.
    public static func decide(
        messages: [AgentMessage],
        available: [RouterModel],
        excluding: Set<String> = [],
        tierOf: (RouterModel) -> ModelTier = { tier(of: $0) }
    ) -> ModelDecision? {
        let available = available.filter { !excluding.contains($0.provider) }
        guard !available.isEmpty else { return nil }
        let role = self.role(for: messages)
        let target: ModelTier = role == .planner ? .premium : .light
        // A turn that only consumes a tool result is mechanical. Every other worker
        // turn still writes code, and stacking a light model with the lowest effort
        // downgrades it twice for no measured saving.
        let mechanical = messages.last?.role == .tool

        // Walk down from the target tier: a premium plan is better than no plan,
        // but if nothing premium is connected, the best standard model still runs.
        let candidate = firstModel(atOrBelow: target, in: available, tierOf: tierOf)
            ?? firstModel(atOrAbove: target, in: available, tierOf: tierOf)
        guard let candidate else { return nil }

        let effort = self.effort(for: role, supported: candidate.efforts, mechanical: mechanical)
        return ModelDecision(
            model: candidate.id,
            effort: effort,
            role: role.rawValue,
            reason: reason(role: role, model: candidate, effort: effort)
        )
    }

    public static func tier(of model: RouterModel) -> ModelTier {
        model.tier ?? ModelTier.inferred(from: model.id)
    }

    // MARK: Role

    static func role(for messages: [AgentMessage]) -> ModelRole {
        // A turn that exists to consume tool output is continuation work.
        if messages.last?.role == .tool { return .worker }
        // Nothing has been decided yet — the opening turn sets the direction.
        let hasPlan = messages.contains { $0.role == .assistant }
        if !hasPlan { return .planner }

        let latest = (messages.last { $0.role == .user }?.content ?? "").lowercased()
        if mechanicalSignals.contains(where: latest.contains) { return .worker }
        if planningSignals.contains(where: latest.contains) { return .planner }
        // Long asks mid-conversation are usually a new sub-task, not a nudge.
        return latest.count > 600 ? .planner : .worker
    }

    // MARK: Effort

    /// Highest supported level for a planner. A worker takes the lowest level only
    /// when the turn is mechanical; otherwise it takes the middle of what the model
    /// offers, since that turn still has to get an edit right.
    /// `none` is only ever chosen when it is the sole option, since it disables
    /// reasoning entirely.
    static func effort(for role: ModelRole, supported: [String], mechanical: Bool = true) -> String {
        let usable = supported.filter { $0 != "none" }
        guard !usable.isEmpty else { return "" }
        let order = ["low", "medium", "high", "xhigh", "max"]
        let ranked = usable.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        if role == .planner { return ranked.last ?? "" }
        if mechanical { return ranked.first ?? "" }
        return ranked[min(1, ranked.count - 1)]
    }

    // MARK: Helpers

    private static func firstModel(
        atOrBelow tier: ModelTier,
        in available: [RouterModel],
        tierOf: (RouterModel) -> ModelTier
    ) -> RouterModel? {
        for candidate in ModelTier.allCases.reversed() where candidate <= tier {
            if let match = available.first(where: { tierOf($0) == candidate }) { return match }
        }
        return nil
    }

    private static func firstModel(
        atOrAbove tier: ModelTier,
        in available: [RouterModel],
        tierOf: (RouterModel) -> ModelTier
    ) -> RouterModel? {
        for candidate in ModelTier.allCases where candidate >= tier {
            if let match = available.first(where: { tierOf($0) == candidate }) { return match }
        }
        return available.first
    }

    private static func reason(role: ModelRole, model: RouterModel, effort: String) -> String {
        let name = model.displayName ?? model.id
        let key = role == .planner ? "auto.reason.planner" : "auto.reason.worker"
        let template = AppCopy.text(key)
        if template == key { return "\(role.rawValue): \(name)" }
        return AppCopy.format(key, name, effort.isEmpty ? "—" : effort)
    }
}
