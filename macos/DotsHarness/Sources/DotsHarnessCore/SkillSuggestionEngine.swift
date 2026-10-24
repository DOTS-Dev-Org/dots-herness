// Copyright (c) 2026 DOTS
// Turns a lesson learned again and again into a skill suggestion. A lesson the
// project keeps relearning is a procedure worth writing down; a repeated shell
// command or a similar prompt is not, so those are no longer mined. Detection only
// ever produces a suggestion; nothing is written until the user accepts it.
// Mirrors shared/SkillSuggestionEngine.cs.

import CryptoKit
import Foundation

public enum SkillSuggestionSignal: String, Sendable {
    /// A lesson learned from at least `SkillSuggestionEngine.lessonHitThreshold` separate events.
    case lesson
    /// The agent itself proposed it via the skill.suggest tool.
    case agentProposed
}

public struct SkillSuggestion: Identifiable, Sendable, Equatable {
    public let id: String
    public let signal: SkillSuggestionSignal
    /// draftName and draftDescription stay as written: they become the saved skill's name and description.
    public let draftName: String
    public let draftDescription: String
    public let body: String

    public var cardTitle: String { AppCopy.format("skill.suggestion.title", draftName) }
    public var cardDescription: String { draftDescription }
}

public enum SkillSuggestionEngine {
    /// Distinct events behind a lesson before it is worth a skill: once is a hint, twice a rule, three times a procedure.
    public static let lessonHitThreshold = 3

    public static func fromLessons(_ lessons: [Lesson]) -> [SkillSuggestion] {
        lessons
            .filter { $0.hits >= lessonHitThreshold && !$0.rule.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.lastSeen > $1.lastSeen }
            .map(fromLesson)
    }

    private static func fromLesson(_ lesson: Lesson) -> SkillSuggestion {
        let rule = lesson.rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let when = lesson.when.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = lesson.why.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = ""
        if !when.isEmpty { body += "## When\n\n\(when)\n\n" }
        body += "## Rule\n\n\(rule)\n\n"
        if !why.isEmpty { body += "## Why\n\n\(why)\n\n" }
        if !lesson.paths.isEmpty { body += "## Applies to\n\n" + lesson.paths.map { "- `\($0)`" }.joined(separator: "\n") + "\n" }
        return SkillSuggestion(
            id: shortHash("lesson:" + lesson.id),
            signal: .lesson,
            draftName: truncate(rule, 60),
            draftDescription: truncate(lesson.line, 200),
            body: body
        )
    }

    private static func truncate(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func shortHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).lowercased()
    }
}
