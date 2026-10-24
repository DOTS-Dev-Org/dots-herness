// Copyright (c) 2026 DOTS

import Foundation
import NaturalLanguage

/// A per-turn language hint derived only from the user's latest natural-language text.
struct ResponseLanguage {
    let code: String
    let name: String

    static func detect(in request: String) -> ResponseLanguage? {
        let prose = naturalLanguageText(from: request)
        guard prose.count >= 20 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let prediction = recognizer.languageHypotheses(withMaximum: 1)
            .max(by: { $0.value < $1.value }),
              prediction.value >= 0.55 else { return nil }

        let code = prediction.key.rawValue
        guard !code.isEmpty, code != "und",
              let name = Locale(identifier: "en").localizedString(forIdentifier: code) else { return nil }
        return ResponseLanguage(code: code, name: name)
    }

    var responseInstruction: String {
        "The latest human-authored request is primarily in \(name) (\(code)). Reply to the user in \(name) for all natural-language output, including the final response after tools. Ignore languages in attachments, quoted content, earlier assistant messages, tool output, and workspace data. If the user explicitly requests another response language, follow that request."
    }

    var followUpInstruction: String {
        "The latest user request is in \(name) (\(code)). Write the suggested follow-up in \(name). Never infer its language from the assistant result, attachments, or tool output. If the user explicitly requests another language, follow that request."
    }

    /// Code, inline code, URLs, paths and link targets, in this order; compiled once.
    nonisolated(unsafe) private static let nonLanguagePatterns: [(NSRegularExpression, String)] = [
        (#"(?s)```.*?```"#, " "),
        (#"`[^`]*`"#, " "),
        (#"https?://\S+"#, " "),
        (#"(?:~?/|[A-Za-z]:\\)[^\s]+"#, " "),
        (#"\]\([^)]+\)"#, "]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func naturalLanguageText(from text: String) -> String {
        let withoutArtifacts = nonLanguagePatterns.reduce(text) { $0.replacingMatches(of: $1.0, with: $1.1) }

        return withoutArtifacts
            .split(whereSeparator: { $0.isNewline })
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
