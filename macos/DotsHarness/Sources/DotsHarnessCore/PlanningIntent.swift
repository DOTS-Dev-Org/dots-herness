import Foundation

/// Gate used before a prompt enters the desktop plan surface. Explicit request
/// shapes are decided locally; anything that merely mentions a "plan" word
/// (plan.md, planet, planını çıkar, ...) is `.ambiguous` and runs as a normal prompt.
/// The phrase set is aligned with shared/PlanningIntent.cs and the mobile agents.
public enum PlanningIntent {
    public enum Verdict: Equatable { case yes, no, ambiguous }

    private static let planningPhrases = [
        "make a plan", "create a plan", "write a plan", "draft a plan",
        "prepare a plan", "give me a plan", "show me a plan", "build a plan",
        "plan this", "plan the", "plan how", "plan out", "implementation plan",
        "action plan", "project plan", "roadmap", "step by step plan",
        "just plan", "plan only", "plan in chat", "plan in a file",
        "write the plan", "save the plan", "write the plan to", "save the plan to",
        "plan changes", "plan changes to", "plan changes in", "plan this file",
        "plan the file", "before coding", "before implementing", "first make a plan",
        "need a plan", "want a plan", "i need a plan",
        "turn on plan mode", "enable plan mode",
        "open plan mode", "plan mode", "switch to plan mode", "go into plan mode",
        "enter plan mode", "open the plan tab", "show plan tab",
        "plan yap", "planla", "planlama", "plan olustur", "plan hazirla",
        "plan yaz", "plan cikar", "plan cikart", "uygulama plani", "eylem plani",
        "yol haritasi", "adim adim plan", "sadece plan", "sohbette plan",
        "chatte plan", "chatte planlama", "sohbette planlama", "plan seklinde",
        "plan formatinda", "dosyaya plan", "dosyaya planlama", "dosyada plan",
        "dosyada planlama", "dosya icin plan", "dosya icin planlama",
        "plani dosyaya", "plan dosyasi",
        "dosyayi planla", "once plan", "once bir plan", "once planla",
        "plan moduna gec", "plan moduna gir", "plan modunu ac", "plan modunu kullan",
        "plan sekmesine gec", "plan sekmesine gir", "plan sekmesini ac", "plan bolumu",
        "plani guncelle", "plani gozden gecir",
        "plani incele",
    ]

    private static let executionPhrases = [
        "apply the plan", "approve plan", "approve the plan", "execute the plan",
        "implement the plan", "run the plan", "use the plan", "proceed with the plan",
        "plani uygula", "plani onayla", "plani hayata gecir", "plani uygulamaya gecir",
        "plani devam ettir", "what is plan mode", "what does plan mode",
        "explain plan mode", "explain what plan mode", "plan mode nedir", "plan modu nedir",
        "plan sekmesi nedir",
    ]

    /// True only for an explicit request; `.ambiguous` needs `resolve`.
    public static func shouldEnterPlanMode(_ text: String?) -> Bool {
        verdict(text) == .yes
    }

    public static func verdict(_ text: String?) -> Verdict {
        guard let text else { return .no }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .no }

        let firstToken = raw.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        if firstToken?.caseInsensitiveCompare("/plan") == .orderedSame { return .yes }

        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return .no }
        // Whole-word matching: "make a plan" must not match "make a planet".
        let padded = " \(normalized) "
        let has: (String) -> Bool = { padded.contains(" \($0) ") }
        if executionPhrases.contains(where: has) { return .no }

        let words = normalized.split(separator: " ").map(String.init)
        if words == ["plan"] || planningPhrases.contains(where: has) { return .yes }
        return words.contains { $0.hasPrefix("plan") } ? .ambiguous : .no
    }

    /// `ask` is only called for `.ambiguous` text and must fail closed (false).
    public static func resolve(_ text: String?, ask: (String) async -> Bool) async -> Bool {
        switch verdict(text) {
        case .yes: return true
        case .no: return false
        case .ambiguous: return await ask(text ?? "")
        }
    }

    private static func normalize(_ text: String) -> String {
        var value = text.lowercased()
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        value = String(value.map { character in
            character.isLetter || character.isNumber ? character : Character(" ")
        })
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension NativeAgentHost {
    /// Ambiguous wording runs as a normal prompt: no model round trip holds the send.
    // ponytail: explicit phrases and /plan still enter plan mode; the override is for tests.
    public func classifyPlanIntent(_ text: String) async -> Bool {
        await planIntentClassifierOverride?(text) ?? false
    }
}
