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
        switch self {
        case .balanced: return AppCopy.language == .tr ? "Dengeli" : "Balanced"
        case .concise: return AppCopy.language == .tr ? "Kısa" : "Concise"
        case .ultra: return AppCopy.language == .tr ? "Ultra kısa" : "Ultra"
        case .detailed: return AppCopy.language == .tr ? "Detaylı" : "Detailed"
        }
    }

    public var detail: String {
        switch self {
        case .balanced:
            return AppCopy.language == .tr ? "Doğal ve dengeli yanıtlar." : "Natural, balanced responses."
        case .concise:
            return AppCopy.language == .tr ? "Kısa ve okunabilir yanıtı tercih eder; tamamlanma veya maliyet garantisi vermez." : "Prefers short, readable responses; it does not guarantee completion or lower usage."
        case .ultra:
            return AppCopy.language == .tr ? "En kısa okunabilir yanıtı best-effort hedefler; tamamlanma garantisi vermez." : "Best-effort shortest readable response; no completion guarantee."
        case .detailed:
            return AppCopy.language == .tr ? "Bağlamı ve gerekçeyi daha kapsamlı açıklar." : "Provides fuller context and explanation."
        }
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
    /// Word limits are converted conservatively for providers that expose only
    /// a token ceiling; the prompt still carries the exact word constraint.
    /// This is an upper bound only when the provider supports the mapped field,
    /// and never a completion guarantee.
    public var providerOutputTokenCap: Int? {
        if let maxOutputTokens { return maxOutputTokens }
        guard let maxWords else { return nil }
        return maxWords > Int.max / 2 ? Int.max : max(1, maxWords * 2)
    }

    /// Aviation "dark cockpit": a quiet panel means everything is normal, so
    /// only the abnormal and the actionable earn output tokens.
    static let darkCockpit = " Dark cockpit rule: silence means normal. Report only results, deviations, failures, and decisions the user must make; never narrate steps or restate what went as expected."
    /// The macOS conversation draws `flow` and `chart` fences, so a process or
    /// a data set costs one short line per item instead of paragraphs.
    static let visualHint = " Show, do not describe: for a process, a request/response path, or how a change you made works, use a ```flow fence with one `stage: short note` line per stage in order; for three or more comparable numbers, use a ```chart fence with one `label: number` line per value. Never repeat a fence's content in prose."

    public var guidance: String {
        switch style {
        case .standard:
            return ""
        case .concise:
            return "Concise: short, direct prose for this turn. No preamble, optional explanation, or alternatives." + Self.darkCockpit + Self.visualHint
        case .ultra:
            return "Ultra: terse prose for this turn. Only the answer and the evidence it needs." + Self.darkCockpit + Self.visualHint
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

    private static func parseLimit(_ normalized: String) -> (tokens: Int?, words: Int?) {
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (nil, nil) }
        for index in 0..<(words.count - 1) {
            guard let value = Int(words[index]), value > 0 else { continue }
            switch words[index + 1] {
            case "token", "tokens": return (value, nil)
            case "kelime", "kelimelik", "kelimeyi", "word", "words": return (nil, value)
            default: continue
            }
        }
        return (nil, nil)
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
