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
    case keepProjectStyle = "keep_project_style"
    case reuseTokenPattern = "reuse_token_pattern"
    case reuseArchitecture = "reuse_architecture"
    case applyElsewhere = "apply_elsewhere"
    case incorrectIncomplete = "incorrect_incomplete"
    case didNotFollowInstructions = "did_not_follow_instructions"
    case offTopicOutOfScope = "off_topic_out_of_scope"
    case lostContext = "lost_context"
    case slowOrBuggy = "slow_or_buggy"
    case securityOrLegalIssue = "security_or_legal_issue"
    case negativeOther = "negative_other"
    case wrongThemeOrToken = "wrong_theme_or_token"
    case brokeExistingFeature = "broke_existing_feature"
    case ignoredProjectArchitecture = "ignored_project_architecture"
    case didNotFollowProjectStyle = "did_not_follow_project_style"

    public var id: String { rawValue }

    public var feedbackType: FeedbackType {
        switch self {
        case .taskCompleted, .followedInstructions, .outputQuality,
             .fastEfficient, .usefulAutonomy, .positiveOther,
             .keepProjectStyle, .reuseTokenPattern, .reuseArchitecture,
             .applyElsewhere:
            return .good
        case .incorrectIncomplete, .didNotFollowInstructions,
             .offTopicOutOfScope, .lostContext, .slowOrBuggy,
             .securityOrLegalIssue, .negativeOther, .wrongThemeOrToken,
             .brokeExistingFeature, .ignoredProjectArchitecture,
             .didNotFollowProjectStyle:
            return .bad
        }
    }

    public var titleKey: String { "feedback.tag.\(rawValue)" }

    public static var positive: [FeedbackTag] {
        [.taskCompleted, .followedInstructions, .outputQuality, .fastEfficient, .usefulAutonomy, .positiveOther,
         .keepProjectStyle, .reuseTokenPattern, .reuseArchitecture, .applyElsewhere]
    }

    public static var negative: [FeedbackTag] {
        [.incorrectIncomplete, .didNotFollowInstructions, .offTopicOutOfScope, .lostContext, .slowOrBuggy, .securityOrLegalIssue, .negativeOther,
         .wrongThemeOrToken, .brokeExistingFeature, .ignoredProjectArchitecture, .didNotFollowProjectStyle]
    }

    /// These positive tags describe a reusable project approach. Generic
    /// success tags remain gold-example signals and do not invoke the lesson
    /// evaluator by themselves.
    public static var meaningfulPositive: Set<FeedbackTag> {
        [.keepProjectStyle, .reuseTokenPattern, .reuseArchitecture, .applyElsewhere]
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
    /// Which request and answer the feedback was given on, as a hash: the text itself
    /// stays in the conversation and is never copied into memory.
    public let digest: String
    public let feedbackType: FeedbackType
    public let tags: [String]
    public let userComment: String
    public let timestamp: Date

    public var id: String { "\(conversationID):\(messageID)" }

    public static func digest(prompt: String, response: String) -> String {
        SHA256.hash(data: Data((prompt + "\u{0}" + response).utf8)).map { String(format: "%02x", $0) }.joined()
    }

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
        self.digest = Self.digest(prompt: prompt, response: response)
        self.feedbackType = feedbackType
        self.tags = tags
        self.userComment = userComment
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case digest
        case prompt
        case response
        case feedbackType = "feedback_type"
        case tags
        case userComment = "user_comment"
        case timestamp
    }

    /// A record written before the text was dropped still carries it; it is read as
    /// its hash and written back without the text (see `FeedbackStore.dropRawText`).
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try values.decode(String.self, forKey: .conversationID)
        messageID = try values.decode(String.self, forKey: .messageID)
        digest = try values.decodeIfPresent(String.self, forKey: .digest) ?? Self.digest(
            prompt: try values.decodeIfPresent(String.self, forKey: .prompt) ?? "",
            response: try values.decodeIfPresent(String.self, forKey: .response) ?? ""
        )
        feedbackType = try values.decode(FeedbackType.self, forKey: .feedbackType)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        userComment = try values.decodeIfPresent(String.self, forKey: .userComment) ?? ""
        timestamp = try values.decode(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(conversationID, forKey: .conversationID)
        try values.encode(messageID, forKey: .messageID)
        try values.encode(digest, forKey: .digest)
        try values.encode(feedbackType, forKey: .feedbackType)
        try values.encode(tags, forKey: .tags)
        try values.encode(userComment, forKey: .userComment)
        try values.encode(timestamp, forKey: .timestamp)
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

/// Bounds of what the evaluator is shown; see `LessonEvaluator.payload`.
public enum FeedbackEvaluator {
    public static let maxPromptCharacters = 8_000
    public static let maxResponseCharacters = 12_000
    public static let maxCommentCharacters = 2_000
    public static let maxTagCharacters = 1_000
    public static let maxRuleCharacters = 600

    /// Immediate, evaluator-free rule from the user's own negative comment.
    /// Positive comments must be generalized from the complete turn evidence;
    /// copying them verbatim would teach praise rather than a project rule.
    public static func directRule(for record: FeedbackRecord) -> String? {
        guard record.feedbackType == .bad else { return nil }
        let cleaned = HerNessPrompt.mask(record.userComment)
            .components(separatedBy: CharacterSet(charactersIn: "<>`*_").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return "Avoid (user-reported): \(String(cleaned.prefix(maxRuleCharacters - 40)))"
    }

    static func clip(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n[content clipped]"
    }
}

/// A small, workspace-local JSONL store. It owns the generated learned-rule
/// projection as well so a feedback edit can invalidate its old derived
/// artifacts without touching unrelated memory notes.
public final class FeedbackStore: @unchecked Sendable {
    static let rulesStart = "<!-- herness:feedback-rules:start -->"
    static let rulesEnd = "<!-- herness:feedback-rules:end -->"
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "have", "has", "not", "you", "your",
        "bir", "ve", "ile", "için", "icin", "bu", "şu", "su", "olan", "olarak", "çok", "cok", "ama", "de", "da", "mi",
    ]

    /// The person's folder for this project in the user layer (see
    /// `WorkspaceMemory.userMemoryDirectory`). Feedback, lessons and rules are theirs
    /// and never go into the repository. Nil until the project has an id.
    public let directory: URL?
    let fileManager: FileManager
    private let lock = NSLock()

    public init(directory: URL?, fileManager: FileManager = .default) {
        self.directory = directory?.standardizedFileURL
        self.fileManager = fileManager
    }

    public var isAvailable: Bool { directory != nil }

    public func record(conversationID: String, messageID: String) -> FeedbackRecord? {
        withLock { loadUnlocked().first { $0.conversationID == conversationID && $0.messageID == messageID } }
    }

    public func records() -> [FeedbackRecord] {
        withLock { loadUnlocked() }
    }

    public func upsert(_ record: FeedbackRecord) throws {
        try withLock {
            guard directory != nil else { throw FeedbackError.unavailable }
            var all = loadUnlocked()
            all.removeAll { $0.id == record.id }
            all.append(record)
            all.sort { $0.timestamp < $1.timestamp }
            try writeJSONLLines(all)
        }
    }

    /// Removes what earlier versions kept of the conversation: the request and answer
    /// inside each record, and the approved answers copied out as examples.
    public func dropRawText() {
        withLock {
            try? fileManager.removeItem(at: url(for: "gold_examples.json"))
            guard let text = try? String(contentsOf: url(for: "feedback.jsonl"), encoding: .utf8),
                  text.contains("\"prompt\":") || text.contains("\"response\":") else { return }
            try? writeJSONLLines(loadUnlocked())
        }
    }

    /// A stable, non-path-bearing key used in the generated markdown marker.
    public func derivedKey(for record: FeedbackRecord) -> String {
        let bytes = Data(record.id.utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    struct FileStamp: Equatable {
        let modified: Date?
        let size: Int?

        init(_ url: URL, fileManager: FileManager) {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            modified = attributes?[.modificationDate] as? Date
            size = (attributes?[.size] as? NSNumber)?.intValue
        }
    }

    /// The chat asks for the feedback of every message on every redraw; the file is
    /// re-read only when it changed on disk.
    private var loadCache: (stamp: FileStamp, records: [FeedbackRecord])?
    /// lessons.json is read for every prompt and every file tool call.
    var lessonsCache: (stamp: FileStamp, lessons: [Lesson])?

    func loadUnlocked() -> [FeedbackRecord] {
        guard let url = directory.map({ $0.appendingPathComponent("feedback.jsonl") }) else { return [] }
        let stamp = FileStamp(url, fileManager: fileManager)
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

    func writeData(_ data: Data, to name: String, permissions: Int16? = nil) throws {
        guard let root = directory else { throw FeedbackError.unavailable }
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

    func generatedRules(in text: String) -> [String: String] {
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

    /// Content words of a text; shared with the task-history selection.
    /// Lowercased without diacritics, so "arayüzü" and "arayuzu" are one word.
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func folded(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
            .lowercased()
            .replacingOccurrences(of: "ı", with: "i")
    }

    static func tokens(_ value: String) -> Set<String> {
        Set(folded(value).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter {
            $0.count >= 3 && !stopWords.contains($0)
        })
    }

    func url(for name: String) -> URL {
        directory?.appendingPathComponent(name) ?? URL(fileURLWithPath: "/dev/null")
    }

    func makeEncoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
