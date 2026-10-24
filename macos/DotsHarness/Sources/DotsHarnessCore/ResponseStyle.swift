import Foundation

public enum AgentResponseStyle: String, Sendable, Codable, Equatable {
    case standard
    case concise
    case ultra
    case detailed
    case strict
}

/// Persistent response preference shown in Settings. This is deliberately
/// separate from the transport style: `strict` is only a per-turn numeric
/// provider ceiling, while these four values are user-controlled defaults.
public enum AgentResponseStylePreference: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
    case balanced
    case concise
    case ultra
    case detailed

    public static let settingsKey = "agent.responseStyle"
    public var id: String { rawValue }

    public var decision: ResponseStyleDecision {
        switch self {
        case .balanced: return ResponseStyleDecision(style: .standard)
        case .concise: return ResponseStyleDecision(style: .concise)
        case .ultra: return ResponseStyleDecision(style: .ultra)
        case .detailed: return ResponseStyleDecision(style: .detailed)
        }
    }

    public var title: String {
        AppCopy.text("responseStyle.\(rawValue)")
    }

    public var detail: String {
        AppCopy.text("responseStyle.\(rawValue).detail")

    }
}

public struct ResponseStyleDecision: Sendable, Equatable {
    public let style: AgentResponseStyle
    public let maxOutputTokens: Int?
    public let maxWords: Int?

    public init(style: AgentResponseStyle, maxOutputTokens: Int? = nil, maxWords: Int? = nil) {
        self.style = style
        self.maxOutputTokens = maxOutputTokens
        self.maxWords = maxWords
    }

    public var isShort: Bool {
        switch style {
        case .concise, .ultra, .strict: return true
        case .standard, .detailed: return false
        }
    }
    public var isHardLimit: Bool { style == .strict }
    /// Only an explicit token ceiling becomes a provider cap. Word limits stay in
    /// the prompt: a words-to-tokens guess is not measured for every language, and
    /// when it is too tight the turn ends with an output-limit failure.
    public var providerOutputTokenCap: Int? { maxOutputTokens }

    /// Aviation "dark cockpit": a quiet panel means everything is normal, so
    /// only the abnormal and the actionable earn output tokens.
    static let darkCockpit = " Dark cockpit rule: state the requested result and evidence, including passing checks. Progress updates stay required but brief. Report failures, deviations and required decisions; omit repeated plans, expected outcomes and tool-by-tool narration. Use an optional diagram only when clearer than prose."

    public var guidance: String {
        switch style {
        case .standard:
            return ""
        case .concise:
            return "Concise: short, direct prose for this turn. No preamble, optional explanation, or alternatives." + Self.darkCockpit
        case .ultra:
            return "Ultra: terse prose for this turn. Only the answer and the evidence it needs." + Self.darkCockpit
        case .detailed:
            return "For this turn, explain the answer clearly and thoroughly. Include the relevant context, reasoning, trade-offs, and verification details, but avoid repetition and unrelated alternatives."
        case .strict:
            let limit: String
            if let maxOutputTokens {
                limit = "Do not exceed \(maxOutputTokens) output tokens."
            } else if let maxWords {
                limit = "Do not exceed \(maxWords) words."
            } else {
                limit = "Stay within the requested output limit."
            }
            return "\(limit) Give the shortest useful answer. If the limit is too low to finish, say what is missing; do not claim the limit is enforced by the provider."
        }
    }
}

/// Resolves a Settings preference without rewriting the user's prompt. Only an
/// explicit numeric token/word ceiling can temporarily override the preference;
/// ordinary words such as "kısaca" are not inspected by the runtime path.
public enum ResponseStyleResolver {
    public static func resolve(
        preference: AgentResponseStylePreference,
        prompt: String?
    ) -> ResponseStyleDecision {
        ResponseStyleDetector.detectLimit(prompt) ?? preference.decision
    }
}

public enum ResponseStyleDetector {
    private static let detailPhrases = [
        "detaylı anlat", "detayli anlat", "ayrıntılı anlat", "ayrintili anlat",
        "uzun anlat", "detay ver", "detayları ver", "detaylari ver",
        "detaylı açıkla", "detayli acikla", "ayrıntılı açıkla", "ayrintili acikla",
        "kısa cevap verme", "kisa cevap verme", "kısa verme", "kisa verme",
        "do not be brief", "do not be concise", "explain in detail", "be detailed",
        "long answer", "full explanation",
    ]

    private static let ultraPhrases = [
        "çok kısa", "cok kisa", "tek cümle", "tek cumle", "tek satır", "tek satir",
        "caveman", "ultra short", "one sentence", "one line", "telegraphic",
    ]

    private static let concisePhrases = [
        "kısaca", "kisaca", "kısa cevap", "kisa cevap", "özetle", "ozetle",
        "özet olarak", "ozet olarak", "az token", "daha az token", "token kullanma",
        "gereksiz açıklama yapma", "gereksiz aciklama yapma", "kısa anlat", "kisa anlat",
        "briefly", "be concise", "concise answer", "summarize", "short answer",
        "use fewer tokens", "use less tokens", "no unnecessary explanation",
    ]

    public static func detect(_ text: String?) -> ResponseStyleDecision {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ResponseStyleDecision(style: .standard)
        }
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return ResponseStyleDecision(style: .standard) }
        let padded = " \(normalized) "
        func contains(_ phrase: String) -> Bool {
            padded.contains(" \(normalize(phrase)) ")
        }

        if let limit = limitDecision(normalized) { return limit }
        if detailPhrases.contains(where: contains) { return ResponseStyleDecision(style: .standard) }
        if ultraPhrases.contains(where: contains) {
            return ResponseStyleDecision(style: .ultra)
        }
        if concisePhrases.contains(where: contains) {
            return ResponseStyleDecision(style: .concise)
        }
        return ResponseStyleDecision(style: .standard)
    }

    /// The runtime uses only this explicit-limit parser. Phrase-based
    /// detection remains available for compatibility/tests, but Settings is
    /// authoritative for the normal response style.
    public static func detectLimit(_ text: String?) -> ResponseStyleDecision? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        return limitDecision(normalized)
    }

    private static func limitDecision(_ normalized: String) -> ResponseStyleDecision? {
        let limit = parseLimit(normalized)
        guard limit.tokens != nil || limit.words != nil else { return nil }
        return ResponseStyleDecision(style: .strict, maxOutputTokens: limit.tokens, maxWords: limit.words)
    }

    /// A count is a limit only with a limit cue beside it ("en fazla 200 token",
    /// "max 50 words", "100 kelimeyi geçme"). Bare counts such as "Add 2 words to the
    /// commit message" or "512 token limit to the prompt builder" are task content.
    private static let limitCuesBefore = [
        "en fazla", "en cok", "at most", "no more than", "not more than", "up to",
        "less than", "fewer than", "under", "below", "within", "exceed", "max", "maximum", "maksimum",
    ]
    private static let limitCuesAfter: Set<String> = [
        "gecme", "gecmesin", "gecmeyin", "gecmeyecek", "asma", "asmasin", "asmayin", "asmayacak",
        "sinirla", "sinirlandir", "max", "maximum", "maksimum",
    ]

    private static func parseLimit(_ normalized: String) -> (tokens: Int?, words: Int?) {
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (nil, nil) }
        for index in 0..<(words.count - 1) {
            guard let value = Int(words[index]), value > 0 else { continue }
            let unit = words[index + 1]
            let isTokens = unit == "token" || unit == "tokens"
            let isWords = ["kelime", "kelimelik", "kelimeyi", "word", "words"].contains(unit)
            guard isTokens || isWords else { continue }
            let before = words[max(0, index - 3)..<index].joined(separator: " ")
            let after = words[min(words.count, index + 2)..<min(words.count, index + 4)]
            guard hasLimitCue(before: before, after: after) else { continue }
            return isTokens ? (value, nil) : (nil, value)
        }
        return (nil, nil)
    }

    private static func hasLimitCue(before: String, after: ArraySlice<String>) -> Bool {
        if limitCuesBefore.contains(where: { before == $0 || before.hasSuffix(" " + $0) }) { return true }
        return after.contains { limitCuesAfter.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        let lowered = value.lowercased().replacingOccurrences(of: "ı", with: "i")
        let folded = lowered.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let cleaned = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .joined(separator: " ")
    }
}
