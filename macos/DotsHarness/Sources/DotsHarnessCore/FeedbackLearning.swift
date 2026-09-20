// Copyright (c) 2026 DOTS
// Local feedback capture and derived project memory.

import CryptoKit
import Foundation

public enum FeedbackType: String, Codable, Sendable, Equatable {
    case good
    case bad
}

/// Stable identifiers are persisted instead of localized labels so changing
/// the app language never changes the meaning of an existing feedback record.
public enum FeedbackTag: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case taskCompleted = "task_completed"
    case followedInstructions = "followed_instructions"
    case outputQuality = "output_quality"
    case fastEfficient = "fast_efficient"
    case usefulAutonomy = "useful_autonomy"
    case positiveOther = "positive_other"
    case incorrectIncomplete = "incorrect_incomplete"
    case didNotFollowInstructions = "did_not_follow_instructions"
    case offTopicOutOfScope = "off_topic_out_of_scope"
    case lostContext = "lost_context"
    case slowOrBuggy = "slow_or_buggy"
    case securityOrLegalIssue = "security_or_legal_issue"
    case negativeOther = "negative_other"

    public var id: String { rawValue }

    public var feedbackType: FeedbackType {
        switch self {
        case .taskCompleted, .followedInstructions, .outputQuality,
             .fastEfficient, .usefulAutonomy, .positiveOther:
            return .good
        case .incorrectIncomplete, .didNotFollowInstructions,
             .offTopicOutOfScope, .lostContext, .slowOrBuggy,
             .securityOrLegalIssue, .negativeOther:
            return .bad
        }
    }

    public var titleKey: String { "feedback.tag.\(rawValue)" }

    public static var positive: [FeedbackTag] {
        [.taskCompleted, .followedInstructions, .outputQuality, .fastEfficient, .usefulAutonomy, .positiveOther]
    }

    public static var negative: [FeedbackTag] {
        [.incorrectIncomplete, .didNotFollowInstructions, .offTopicOutOfScope, .lostContext, .slowOrBuggy, .securityOrLegalIssue, .negativeOther]
    }

    public static func tags(for type: FeedbackType) -> [FeedbackTag] {
        type == .good ? positive : negative
    }
}

public struct FeedbackTarget: Identifiable, Equatable, Sendable {
    public let conversationID: String
    public let messageID: String
    public let feedbackType: FeedbackType

    public var id: String {
        "\(conversationID):\(messageID):\(feedbackType.rawValue)"
    }

    public init(conversationID: String, messageID: String, feedbackType: FeedbackType) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.feedbackType = feedbackType
    }
}

public struct FeedbackRecord: Codable, Equatable, Identifiable, Sendable {
    public let conversationID: String
    public let messageID: String
    public let prompt: String
    public let response: String
    public let feedbackType: FeedbackType
    public let tags: [String]
    public let userComment: String
    public let timestamp: Date

    public var id: String { "\(conversationID):\(messageID)" }

    public init(
        conversationID: String,
        messageID: String,
        prompt: String,
        response: String,
        feedbackType: FeedbackType,
        tags: [String] = [],
        userComment: String = "",
        timestamp: Date = Date()
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.prompt = prompt
        self.response = response
        self.feedbackType = feedbackType
        self.tags = tags
        self.userComment = userComment
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case prompt
        case response
        case feedbackType = "feedback_type"
        case tags
        case userComment = "user_comment"
        case timestamp
    }
}

public enum FeedbackError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case conversationNotFound
    case messageNotFound
    case unsupportedMessage
    case streamingMessage
    case missingPrompt
    case missingResponse
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: return AppCopy.text("feedback.unavailable")
        case .conversationNotFound: return AppCopy.text("feedback.conversationNotFound")
        case .messageNotFound: return AppCopy.text("feedback.messageNotFound")
        case .unsupportedMessage: return AppCopy.text("feedback.unsupportedMessage")
        case .streamingMessage: return AppCopy.text("feedback.streamingMessage")
        case .missingPrompt: return AppCopy.text("feedback.missingPrompt")
        case .missingResponse: return AppCopy.text("feedback.missingResponse")
        case .persistenceFailed: return AppCopy.text("feedback.persistenceFailed")
        }
    }
}

/// The evaluator receives only a bounded, redacted representation. The raw
/// prompt and response remain local in feedback.jsonl and are never needed by
/// the evaluator after this value is built.
public enum FeedbackEvaluator {
    public static let maxPromptCharacters = 8_000
    public static let maxResponseCharacters = 12_000
    public static let maxCommentCharacters = 2_000
    public static let maxTagCharacters = 1_000
    public static let maxRuleCharacters = 600

    public static func payload(for record: FeedbackRecord) -> String {
        let body = [
            "Feedback type: \(record.feedbackType.rawValue)",
            "Tags: \(clip(record.tags.prefix(32).joined(separator: ", "), to: maxTagCharacters))",
            "User comment:\n\(clip(HerNessPrompt.mask(record.userComment), to: maxCommentCharacters))",
            "User prompt:\n\(clip(HerNessPrompt.mask(record.prompt), to: maxPromptCharacters))",
            "Assistant response:\n\(clip(HerNessPrompt.mask(record.response), to: maxResponseCharacters))",
        ].joined(separator: "\n\n")
        return HerNessPrompt.assemble([
            PromptSection(tag: "feedback_event", trust: .data, text: body),
        ])
    }

    /// Only an exact JSON object with one string field is accepted. Markdown
    /// fences, extra keys, XML-like markup, and multi-paragraph explanations
    /// are deliberately rejected before anything reaches project memory.
    public static func parseNegativeConstraint(from content: String) -> String? {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["negative_constraint"],
              let raw = object["negative_constraint"] as? String else {
            return nil
        }
        let value = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !value.isEmpty,
              value.count <= maxRuleCharacters,
              !value.contains("<"),
              !value.contains(">"),
              !value.contains("```"),
              !value.contains("`"),
              !value.contains("**"),
              !value.contains("__"),
              !value.contains("<!--"),
              !value.contains("-->") else {
            return nil
        }
        let sentenceStops = value.filter { ".!?".contains($0) }.count
        guard sentenceStops <= 2 else { return nil }
        return value
    }

    private static func clip(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n[content clipped]"
    }
}

/// A small, workspace-local JSONL store. It owns the generated gold-example
/// and learned-rule projections as well so a feedback edit can invalidate its
/// old derived artifacts without touching unrelated memory notes.
public final class FeedbackStore: @unchecked Sendable {
    private struct GoldExample: Codable, Sendable {
        let conversationID: String
        let messageID: String
        let prompt: String
        let response: String
        let tags: [String]
        let timestamp: Date

        init(_ record: FeedbackRecord) {
            conversationID = record.conversationID
            messageID = record.messageID
            prompt = record.prompt
            response = record.response
            tags = record.tags
            timestamp = record.timestamp
        }

        private enum CodingKeys: String, CodingKey {
            case conversationID = "conversation_id"
            case messageID = "message_id"
            case prompt
            case response
            case tags
            case timestamp
        }
    }

    private static let rulesStart = "<!-- herness:feedback-rules:start -->"
    private static let rulesEnd = "<!-- herness:feedback-rules:end -->"
    private static let maxRulesCharacters = 16_000
    private static let maxExamplesCharacters = 14_000
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "have", "has", "not", "you", "your",
        "bir", "ve", "ile", "için", "icin", "bu", "şu", "su", "olan", "olarak", "çok", "cok", "ama", "de", "da", "mi",
    ]

    public let workspaceURL: URL?
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(workspaceURL: URL?, fileManager: FileManager = .default) {
        self.workspaceURL = workspaceURL?.standardizedFileURL
        self.fileManager = fileManager
    }

    public var isAvailable: Bool { workspaceURL != nil }

    public func record(conversationID: String, messageID: String) -> FeedbackRecord? {
        withLock { loadUnlocked().first { $0.conversationID == conversationID && $0.messageID == messageID } }
    }

    public func records() -> [FeedbackRecord] {
        withLock { loadUnlocked() }
    }

    public func upsert(_ record: FeedbackRecord) throws {
        try withLock {
            guard workspaceURL != nil else { throw FeedbackError.unavailable }
            var all = loadUnlocked()
            all.removeAll { $0.id == record.id }
            all.append(record)
            all.sort { $0.timestamp < $1.timestamp }
            try writeJSONLLines(all)
        }
    }

    /// Rebuilds the current positive projection from the current feedback
    /// records. The file is intentionally an array so it remains easy to read
    /// and consume without a JSON database dependency.
    public func rebuildGoldExamples() throws {
        try withLock {
            guard workspaceURL != nil else { throw FeedbackError.unavailable }
            let examples = loadUnlocked()
                .filter { $0.feedbackType == .good }
                .map(GoldExample.init)
            let encoder = makeEncoder()
            do {
                try writeData(encoder.encode(examples), to: "gold_examples.json")
            } catch {
                throw FeedbackError.persistenceFailed
            }
        }
    }

    /// Adds, replaces, or removes only the generated line for one feedback
    /// record. Manual content outside the marked block is preserved verbatim.
    public func setLearnedRule(_ rule: String?, for record: FeedbackRecord) throws {
        try withLock {
            guard workspaceURL != nil else { throw FeedbackError.unavailable }
            do {
                try replaceGeneratedRuleUnlocked(rule, key: derivedKey(for: record))
            } catch {
                throw FeedbackError.persistenceFailed
            }
        }
    }

    /// Combines native project memory with bounded learned rules and relevant
    /// gold examples. The caller wraps this result in project_memory/data.
    public func context(for prompt: String, baseMemory: String) -> String {
        withLock {
            var parts: [String] = []
            if !baseMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(baseMemory)
            }

            if let rules = try? String(contentsOf: url(for: "learned_rules.md"), encoding: .utf8),
               !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("## Learned rules\n\(clip(rules, to: Self.maxRulesCharacters))")
            }

            let examples = selectedExamples(for: prompt)
            if !examples.isEmpty {
                parts.append("## Gold examples (reference only)\n\(format(examples))")
            }
            return parts.joined(separator: "\n\n")
        }
    }

    /// A stable, non-path-bearing key used in the generated markdown marker.
    public func derivedKey(for record: FeedbackRecord) -> String {
        let bytes = Data(record.id.utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private struct FileStamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    /// The chat asks for the feedback of every message on every redraw; the file is
    /// re-read only when it changed on disk.
    private var loadCache: (stamp: FileStamp, records: [FeedbackRecord])?

    private func loadUnlocked() -> [FeedbackRecord] {
        guard let url = workspaceURL.map({ $0.appendingPathComponent(".mem", isDirectory: true).appendingPathComponent("feedback.jsonl") }) else { return [] }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let stamp = FileStamp(
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.intValue
        )
        if let loadCache, loadCache.stamp == stamp { return loadCache.records }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            loadCache = nil
            return []
        }
        let decoder = makeDecoder()
        var latest: [String: FeedbackRecord] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let record = try? decoder.decode(FeedbackRecord.self, from: data) else { continue }
            latest[record.id] = record
        }
        let sorted = latest.values.sorted { $0.timestamp < $1.timestamp }
        loadCache = (stamp, sorted)
        return sorted
    }

    private func writeJSONLLines(_ records: [FeedbackRecord]) throws {
        let encoder = makeEncoder(prettyPrinted: false)
        do {
            let lines = try records.map { try encoder.encode($0) }
            let data = lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
            try writeData(Data((data + (data.isEmpty ? "" : "\n")).utf8), to: "feedback.jsonl", permissions: 0o600)
        } catch let error as FeedbackError {
            throw error
        } catch {
            throw FeedbackError.persistenceFailed
        }
    }

    private func writeData(_ data: Data, to name: String, permissions: Int16? = nil) throws {
        guard let workspaceURL else { throw FeedbackError.unavailable }
        let root = workspaceURL.appendingPathComponent(".mem", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(name)
            try data.write(to: destination, options: .atomic)
            if let permissions {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
            }
        } catch {
            throw FeedbackError.persistenceFailed
        }
    }

    private func replaceGeneratedRuleUnlocked(_ rule: String?, key: String) throws {
        let destination = url(for: "learned_rules.md")
        let existing = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        var generated = generatedRules(in: existing)
        if let rule, !rule.isEmpty {
            generated[key] = rule
        } else {
            generated.removeValue(forKey: key)
        }

        let ruleLines = generated.keys.sorted().map { key in
            "- [feedback:\(key)] \(generated[key] ?? "")"
        }
        let block = generated.isEmpty ? "" : [
            Self.rulesStart,
            ruleLines.joined(separator: "\n"),
            Self.rulesEnd,
        ].joined(separator: "\n")

        let prefix: String
        let suffix: String
        if let start = existing.range(of: Self.rulesStart),
           let end = existing.range(of: Self.rulesEnd, range: start.upperBound..<existing.endIndex) {
            prefix = String(existing[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            suffix = String(existing[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            prefix = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "# Learned rules\n\nRules inferred from explicit negative feedback."
                : existing.trimmingCharacters(in: .whitespacesAndNewlines)
            suffix = ""
        }

        let content = [prefix, block, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        try writeData(Data((content + (content.isEmpty ? "" : "\n")).utf8), to: "learned_rules.md")
    }

    private func generatedRules(in text: String) -> [String: String] {
        guard let start = text.range(of: Self.rulesStart),
              let end = text.range(of: Self.rulesEnd, range: start.upperBound..<text.endIndex) else { return [:] }
        let body = text[start.upperBound..<end.lowerBound]
        var result: [String: String] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard value.hasPrefix("- [feedback:"),
                  let close = value.firstIndex(of: "]"),
                  close > value.index(value.startIndex, offsetBy: 12) else { continue }
            let keyStart = value.index(value.startIndex, offsetBy: 12)
            let key = String(value[keyStart..<close])
            let ruleStart = value.index(after: close)
            let rule = value[ruleStart...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !rule.isEmpty { result[key] = rule }
        }
        return result
    }

    private func selectedExamples(for prompt: String) -> [GoldExample] {
        guard let data = try? Data(contentsOf: url(for: "gold_examples.json")),
              let examples = try? makeDecoder().decode([GoldExample].self, from: data) else { return [] }
        let promptTokens = tokens(prompt)
        guard !promptTokens.isEmpty else { return [] }
        return examples.compactMap { example -> (Double, GoldExample)? in
            let exampleTokens = tokens(example.prompt + " " + example.response)
            let overlap = promptTokens.intersection(exampleTokens).count
            guard overlap > 0 else { return nil }
            let union = promptTokens.union(exampleTokens).count
            let score = Double(overlap) / Double(max(1, union))
            return (score, example)
        }
        .sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            return $0.1.timestamp > $1.1.timestamp
        }
        .prefix(3)
        .map(\.1)
    }

    private func format(_ examples: [GoldExample]) -> String {
        var output = ""
        for (index, example) in examples.enumerated() {
            let block = [
                "### Example \(index + 1)",
                "Prompt:\n\(clip(example.prompt, to: 3_000))",
                "Response:\n\(clip(example.response, to: 6_000))",
            ].joined(separator: "\n")
            let candidate = output.isEmpty ? block : output + "\n\n" + block
            guard candidate.count <= Self.maxExamplesCharacters else { break }
            output = candidate
        }
        return output
    }

    private func tokens(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter {
            $0.count >= 3 && !Self.stopWords.contains($0)
        })
    }

    private func clip(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n[content clipped]"
    }

    private func url(for name: String) -> URL {
        workspaceURL?.appendingPathComponent(".mem", isDirectory: true).appendingPathComponent(name)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    private func makeEncoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
