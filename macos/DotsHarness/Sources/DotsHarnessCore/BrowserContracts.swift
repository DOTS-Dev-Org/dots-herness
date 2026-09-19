// Copyright (c) 2026 DOTS
// Browser capability contracts for the native macOS harness.

import Foundation

public enum BrowserBackend: String, Codable, Sendable, Equatable {
    case managed = "Managed"
    case `extension` = "Extension"
    case unknown = "Unknown"
}

public enum BrowserCleanupStatus: String, Codable, Sendable, Equatable {
    case notUsed = "NotUsed"
    case closed = "Closed"
    case pendingRecovery = "PendingRecovery"
    case failed = "Failed"
}

public struct BrowserScope: Codable, Sendable, Equatable, Hashable {
    public let area: String
    public let conversationID: String
    public let runID: String

    public init(area: String, conversationID: String, runID: String) {
        self.area = area
        self.conversationID = conversationID
        self.runID = runID
    }

    public var key: String { "\(area):\(conversationID):\(runID)" }
}

public struct BrowserPage: Codable, Sendable, Equatable {
    public let pageID: String
    public let backend: BrowserBackend
    public let url: String
    public let scope: BrowserScope

    public init(pageID: String, backend: BrowserBackend, url: String, scope: BrowserScope) {
        self.pageID = pageID
        self.backend = backend
        self.url = url
        self.scope = scope
    }
}

public struct BrowserRunSummary: Codable, Sendable, Equatable, Hashable {
    public let backend: BrowserBackend
    public let openedPageIDs: [String]
    public let closedPageIDs: [String]
    public let cleanupStatus: BrowserCleanupStatus
    public let diagnosticCode: String

    public init(
        backend: BrowserBackend,
        openedPageIDs: [String] = [],
        closedPageIDs: [String] = [],
        cleanupStatus: BrowserCleanupStatus = .notUsed,
        diagnosticCode: String = "not_used"
    ) {
        self.backend = backend
        self.openedPageIDs = openedPageIDs
        self.closedPageIDs = closedPageIDs
        self.cleanupStatus = cleanupStatus
        self.diagnosticCode = diagnosticCode
    }
}

public enum BrowserBackendPolicy {
    public static func resolveUserRule(_ userText: String?) -> BrowserBackend {
        guard let userText, !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown
        }
        let value = userText.lowercased()
        if containsAny(value,
                       "mevcut chrome", "chrome profilimi", "chrome oturumumu", "oturum açılmış chrome",
                       "oturum acilmis chrome", "current chrome", "existing chrome", "logged-in chrome",
                       "logged in chrome", "use my chrome", "use existing chrome", "my chrome profile") {
            return .`extension`
        }
        if containsAny(value,
                       "managed browser", "isolated browser", "clean browser", "temporary browser",
                       "izole tarayıcı", "izole tarayici", "temiz tarayıcı", "temiz tarayici",
                       "managed chrome", "clean profile", "temiz profil") {
            return .managed
        }
        return .unknown
    }

    public static func parseConfirmation(_ answer: String?) -> BrowserBackend {
        guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown
        }
        let value = answer.lowercased()
        if containsAny(value, "extension", "mevcut chrome", "current chrome", "existing chrome", "chrome profile", "existing chrome profile")
            || containsToken(value, "2") {
            return .`extension`
        }
        if containsAny(value, "managed", "izole", "isolated", "clean", "temiz", "managed isolated browser")
            || containsToken(value, "1") {
            return .managed
        }
        return .unknown
    }

    private static func containsAny(_ value: String, _ candidates: String...) -> Bool {
        candidates.contains { value.contains($0) }
    }

    private static func containsToken(_ value: String, _ token: String) -> Bool {
        value.split { character in
            character.isWhitespace || ".,;:!?()[]{}\"'-".contains(character)
        }.contains { $0 == token }
    }
}

public enum BrowserTools {
    public static let openName = "browser_open"
    public static let navigateName = "browser_navigate"
    public static let closeName = "browser_close"

    public static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: openName,
            description: "Open a URL in the host-managed browser session. The host selects the backend; do not pass a backend.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("An http or https URL."),
                    ]),
                ]),
                "required": .array([.string("url")]),
                "additionalProperties": .bool(false),
            ])
        ),
        AgentToolDefinition(
            name: navigateName,
            description: "Navigate an owned browser page. The pageID must come from browser_open.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageID": .object(["type": .string("string")]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("An http or https URL."),
                    ]),
                ]),
                "required": .array([.string("pageID"), .string("url")]),
                "additionalProperties": .bool(false),
            ])
        ),
        AgentToolDefinition(
            name: closeName,
            description: "Close an owned browser page. Pages are also closed automatically when the run ends.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageID": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("pageID")]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]

    public static func backendQuestionCall(_ callID: String) -> AgentToolCall {
        AgentToolCall(
            id: "\(callID):browser-backend",
            name: AskUserTool.name,
            arguments: #"{"questions":[{"header":"Browser","question":"Which browser session should this run use?","options":["Managed isolated browser","Existing Chrome profile"]}]}"#
        )
    }
}
