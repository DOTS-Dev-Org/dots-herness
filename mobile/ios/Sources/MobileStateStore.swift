import Foundation
import SQLite3

struct MobileRuntimeEvent: Identifiable, Equatable, Sendable {
    let id: String
    let conversationID: String?
    let kind: String
    let payload: [String: String]
    let createdAt: Date
}

struct StoredMobileMessage: Identifiable, Equatable, Sendable {
    let id: String
    let rowID: Int64
    let conversationID: String
    let role: String
    let content: String
    let toolName: String?
    let createdAt: Date
}

struct StoredMobileMessagePage: Equatable, Sendable {
    let messages: [StoredMobileMessage]
    let beforeRowID: Int64?
    let hasOlder: Bool
}

struct StoredMobileConversation: Identifiable, Equatable, Sendable {
    let id: String
    let projectID: String
    let status: String
    let updatedAt: Date
    let title: String
    let archived: Bool
}

struct StoredMobileModelContext: Equatable, Sendable {
    let conversationID: String
    let projectID: String
    let content: String
}

/// The on-device state boundary. Credentials never cross this type: SQLite
/// stores only a keychain reference such as `keychain:phone.provider.anthropic`.
@MainActor
final class MobileStateStore {
    nonisolated(unsafe) private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL? = nil) {
        let location = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HerNess/state.sqlite")
        try? FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(location.path, &database) == SQLITE_OK else {
            database = nil
            return
        }
        do {
            try execute("PRAGMA journal_mode = WAL")
            // WAL with NORMAL stays consistent after a crash; FULL fsynced every
            // commit, and this store commits on the main actor at every agent step.
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA foreign_keys = ON")
            try migrate()
            recoverInterruptedRuns()
            pruneEvents()
        } catch {
            // A broken state file must not prevent the app from opening. The
            // next write will surface the failure through the runtime event.
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func startRun(mode: String, planMode: Bool, prompt: String, projectID: String = "local-default") -> String {
        let conversationID = UUID().uuidString
        let actionID = UUID().uuidString
        do {
            try transaction {
                try execute("INSERT INTO conversations(id, project_id, status, mode, plan_mode, created_at, updated_at) VALUES(?, ?, 'running', ?, ?, ?, ?)", [conversationID, projectID, mode, planMode ? "1" : "0", now, now])
                try execute("INSERT INTO pending_actions(id, conversation_id, kind, payload_json, status, created_at, updated_at) VALUES(?, ?, 'run', '{}', 'running', ?, ?)", [actionID, conversationID, now, now])
                try execute("INSERT INTO messages(id, conversation_id, role, content, created_at) VALUES(?, ?, 'user', ?, ?)", [UUID().uuidString, conversationID, MobileEventPayloadSanitizer.redact(prompt), now])
            }
        } catch {
            // Runtime continues in memory if persistence is unavailable.
        }
        return conversationID
    }

    /// Creates a durable conversation before the first prompt is classified or
    /// sent. The initial snapshot lets a queued-only conversation be discovered
    /// after a force quit, even though no provider run has started yet.
    func reserveConversation(projectID: String = "local-default") -> String {
        let conversationID = UUID().uuidString
        do {
            try transaction {
                try execute("INSERT INTO conversations(id, project_id, status, mode, plan_mode, created_at, updated_at) VALUES(?, ?, 'queued', 'agent', 0, ?, ?)", [conversationID, projectID, now, now])
                try execute("INSERT INTO model_context(conversation_id, project_id, content_json, updated_at) VALUES(?, ?, ?, ?)", [conversationID, projectID, "{\"version\":3,\"messages\":[]}", now])
            }
        } catch { }
        return conversationID
    }

    /// Accepts the first prompt and creates its conversation in one durable
    /// transaction. A force-quit can leave neither an empty conversation nor a
    /// visible-but-unrecorded prompt behind.
    func reserveConversation(
        projectID: String = "local-default",
        queuedPrompt: (id: String, payload: String),
        snapshot: String
    ) -> String? {
        let conversationID = UUID().uuidString
        let timestamp = now
        do {
            try transaction {
                try execute("INSERT INTO conversations(id, project_id, status, mode, plan_mode, created_at, updated_at) VALUES(?, ?, 'queued', 'agent', 0, ?, ?)", [conversationID, projectID, timestamp, timestamp])
                try execute("INSERT INTO model_context(conversation_id, project_id, content_json, updated_at) VALUES(?, ?, ?, ?)", [conversationID, projectID, MobileEventPayloadSanitizer.redact(snapshot), timestamp])
                try execute("INSERT INTO queued_prompts(id, conversation_id, position, payload_json, created_at) VALUES(?, ?, 0, ?, ?)", [queuedPrompt.id, conversationID, MobileEventPayloadSanitizer.redact(queuedPrompt.payload), timestamp])
            }
            return conversationID
        } catch {
            return nil
        }
    }

    /// Claims a queued prompt and records its user message atomically. A crash
    /// can therefore leave it either queued or in the transcript, never both.
    @discardableResult
    func beginReservedRun(
        conversationID: String,
        mode: String,
        planMode: Bool,
        prompt: String,
        consumedPromptID: String? = nil,
        projectID: String = "local-default",
        snapshot: String? = nil,
        queuedPrompts: [(id: String, payload: String)]? = nil
    ) -> Bool {
        let timestamp = now
        do {
            try transaction {
                try execute("UPDATE conversations SET status = 'running', mode = ?, plan_mode = ?, updated_at = ? WHERE id = ?", [mode, planMode ? "1" : "0", timestamp, conversationID])
                try execute("INSERT INTO pending_actions(id, conversation_id, kind, payload_json, status, created_at, updated_at) VALUES(?, ?, 'run', '{}', 'running', ?, ?)", [UUID().uuidString, conversationID, timestamp, timestamp])
                try execute("INSERT INTO messages(id, conversation_id, role, content, created_at) VALUES(?, ?, 'user', ?, ?)", [UUID().uuidString, conversationID, MobileEventPayloadSanitizer.redact(prompt), timestamp])
                if let consumedPromptID {
                    try execute("DELETE FROM queued_prompts WHERE id = ? AND conversation_id = ?", [consumedPromptID, conversationID])
                }
                if let snapshot {
                    try execute("INSERT INTO model_context(conversation_id, project_id, content_json, updated_at) VALUES(?, ?, ?, ?) ON CONFLICT(conversation_id) DO UPDATE SET project_id=excluded.project_id, content_json=excluded.content_json, updated_at=excluded.updated_at", [conversationID, projectID, MobileEventPayloadSanitizer.redact(snapshot), timestamp])
                }
                if let queuedPrompts {
                    try execute("DELETE FROM queued_prompts WHERE conversation_id = ?", [conversationID])
                    for (position, queued) in queuedPrompts.enumerated() {
                        try execute("INSERT INTO queued_prompts(id, conversation_id, position, payload_json, created_at) VALUES(?, ?, ?, ?, ?)", [queued.id, conversationID, String(position), MobileEventPayloadSanitizer.redact(queued.payload), timestamp])
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    func appendMessage(conversationID: String?, role: String, content: String, toolName: String? = nil) {
        guard let conversationID else { return }
        do {
            try transaction {
                try execute("INSERT INTO messages(id, conversation_id, role, content, tool_name, created_at) VALUES(?, ?, ?, ?, ?, ?)", [UUID().uuidString, conversationID, role, MobileEventPayloadSanitizer.redact(content), toolName ?? "", now])
                try execute("UPDATE conversations SET updated_at = ? WHERE id = ?", [now, conversationID])
            }
        } catch { }
    }

    func appendEvent(conversationID: String?, projectID: String = "local-default", kind: String, payload: [String: String]) -> MobileRuntimeEvent {
        let safePayload = MobileEventPayloadSanitizer.sanitize(payload)
        let event = MobileRuntimeEvent(id: UUID().uuidString, conversationID: conversationID, kind: kind, payload: safePayload, createdAt: Date())
        let data = (try? JSONEncoder().encode(safePayload)) ?? Data("{}".utf8)
        do {
            try transaction {
                try execute("INSERT INTO events(id, conversation_id, project_id, kind, payload_json, created_at) VALUES(?, ?, ?, ?, ?, ?)", [event.id, conversationID ?? "", projectID, kind, String(decoding: data, as: UTF8.self), String(event.createdAt.timeIntervalSince1970)])
            }
        } catch { }
        return event
    }

    func finishRun(conversationID: String?, status: String) {
        guard let conversationID else { return }
        do {
            try transaction {
                try execute("UPDATE conversations SET status = ?, updated_at = ? WHERE id = ?", [status, now, conversationID])
                try execute("UPDATE pending_actions SET status = ?, updated_at = ? WHERE conversation_id = ? AND status = 'running'", [status, now, conversationID])
            }
        } catch { }
    }

    func savePendingAction(id: String, conversationID: String?, kind: String, payload: [String: String], status: String) {
        guard let conversationID else { return }
        let data = (try? JSONEncoder().encode(MobileEventPayloadSanitizer.sanitize(payload))) ?? Data("{}".utf8)
        do {
            try transaction {
                try execute("INSERT INTO pending_actions(id, conversation_id, kind, payload_json, status, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload_json=excluded.payload_json, status=excluded.status, updated_at=excluded.updated_at", [id, conversationID, kind, String(decoding: data, as: UTF8.self), status, now, now])
            }
        } catch { }
    }

    func resolvePendingAction(id: String, status: String) {
        try? execute("UPDATE pending_actions SET status = ?, updated_at = ? WHERE id = ?", [status, now, id])
    }

    func saveProvider(provider: String, model: String, credentialReference: String) {
        let safeReference = credentialReference.hasPrefix("keychain:") ? credentialReference : "[redacted]"
        let accountID = "phone.\(provider)"
        do {
            try execute("INSERT INTO provider_accounts(id, provider, model, credential_ref, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, model=excluded.model, credential_ref=excluded.credential_ref", [accountID, provider, model, safeReference, now])
            try execute("DELETE FROM provider_accounts WHERE id = 'phone'")
        } catch { }
    }

    func saveOAuth(provider: String, accountReference: String) {
        let timestamp = now
        let safeReference = accountReference.hasPrefix("keychain:") ? accountReference : "[redacted]"
        try? execute("INSERT INTO oauth_accounts(id, provider, account_ref, created_at, updated_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET account_ref=excluded.account_ref, updated_at=excluded.updated_at", [provider, provider, safeReference, timestamp, timestamp])
    }

    func saveRepository(_ repository: RepoCoordinates, localPath: String = "workspace", baseCommit: String? = nil) {
        let timestamp = now
        try? execute("INSERT INTO repositories(id, provider, owner, name, branch, local_path, base_commit, created_at, updated_at) VALUES(?, 'github', ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET branch=excluded.branch, local_path=excluded.local_path, base_commit=excluded.base_commit, updated_at=excluded.updated_at", [
            "github:\(repository.slug)", repository.owner, repository.repository, repository.branch, localPath, baseCommit ?? "", timestamp, timestamp
        ])
    }

    @discardableResult
    func saveModelContext(
        conversationID: String?,
        projectID: String = "local-default",
        content: String,
        queuedPrompts: [(id: String, payload: String)]? = nil
    ) -> Bool {
        guard let conversationID else { return false }
        do {
            try transaction {
                try execute("INSERT INTO model_context(conversation_id, project_id, content_json, updated_at) VALUES(?, ?, ?, ?) ON CONFLICT(conversation_id) DO UPDATE SET project_id=excluded.project_id, content_json=excluded.content_json, updated_at=excluded.updated_at", [conversationID, projectID, MobileEventPayloadSanitizer.redact(content), now])
                if let queuedPrompts {
                    try execute("DELETE FROM queued_prompts WHERE conversation_id = ?", [conversationID])
                    for (position, prompt) in queuedPrompts.enumerated() {
                        try execute("INSERT INTO queued_prompts(id, conversation_id, position, payload_json, created_at) VALUES(?, ?, ?, ?, ?)", [prompt.id, conversationID, String(position), MobileEventPayloadSanitizer.redact(prompt.payload), now])
                    }
                }
                try execute("UPDATE conversations SET updated_at = ? WHERE id = ?", [now, conversationID])
            }
            return true
        } catch {
            return false
        }
    }

    func queuedPromptPayloads(conversationID: String) -> [(id: String, payload: String)] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT id, payload_json FROM queued_prompts WHERE conversation_id = ? ORDER BY position ASC", -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_bind_text(statement, 1, conversationID, -1, transient) == SQLITE_OK else { return [] }
        var result: [(id: String, payload: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let payload = sqlite3_column_text(statement, 1) else { continue }
            result.append((String(cString: id), String(cString: payload)))
        }
        return result
    }

    func latestModelContext(projectID: String = "local-default") -> StoredMobileModelContext? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT conversation_id, project_id, content_json FROM model_context WHERE project_id = ? ORDER BY updated_at DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_bind_text(statement, 1, projectID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let conversation = sqlite3_column_text(statement, 0),
              let project = sqlite3_column_text(statement, 1),
              let content = sqlite3_column_text(statement, 2) else { return nil }
        return StoredMobileModelContext(
            conversationID: String(cString: conversation),
            projectID: String(cString: project),
            content: String(cString: content)
        )
    }

    func modelContext(conversationID: String) -> StoredMobileModelContext? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT conversation_id, project_id, content_json FROM model_context WHERE conversation_id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_bind_text(statement, 1, conversationID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let conversation = sqlite3_column_text(statement, 0),
              let project = sqlite3_column_text(statement, 1),
              let content = sqlite3_column_text(statement, 2) else { return nil }
        return StoredMobileModelContext(
            conversationID: String(cString: conversation),
            projectID: String(cString: project),
            content: String(cString: content)
        )
    }

    func saveSetting(key: String, value: String) {
        try? execute("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    func setting(_ key: String) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM settings WHERE key = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    func recentEvents(projectID: String = "local-default", limit: Int = 500) -> [MobileRuntimeEvent] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT id, conversation_id, kind, payload_json, created_at FROM events WHERE project_id = ? ORDER BY rowid DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        sqlite3_bind_text(statement, 1, projectID, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 2_000))))
        var result: [MobileRuntimeEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let payloadData = sqlite3_column_text(statement, 3).map { Data(String(cString: $0).utf8) } ?? Data("{}".utf8)
            result.append(MobileRuntimeEvent(
                id: String(cString: sqlite3_column_text(statement, 0)),
                conversationID: optionalText(statement, column: 1),
                kind: String(cString: sqlite3_column_text(statement, 2)),
                payload: (try? JSONDecoder().decode([String: String].self, from: payloadData)) ?? [:],
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))))
        }
        return result.reversed()
    }

    func messages(conversationID: String, limit: Int = 10) -> [StoredMobileMessage] {
        messagePage(conversationID: conversationID, limit: limit).messages
    }

    func messagePage(conversationID: String, beforeRowID: Int64? = nil, limit: Int = 10) -> StoredMobileMessagePage {
        guard let database else { return StoredMobileMessagePage(messages: [], beforeRowID: nil, hasOlder: false) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let pageSize = max(1, min(limit, 2_000))
        let sql = beforeRowID == nil
            ? "SELECT rowid, id, conversation_id, role, content, tool_name, created_at FROM messages WHERE conversation_id = ? ORDER BY rowid DESC"
            : "SELECT rowid, id, conversation_id, role, content, tool_name, created_at FROM messages WHERE conversation_id = ? AND rowid < ? ORDER BY rowid DESC"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return StoredMobileMessagePage(messages: [], beforeRowID: nil, hasOlder: false) }
        sqlite3_bind_text(statement, 1, conversationID, -1, transient)
        if let beforeRowID { sqlite3_bind_int64(statement, 2, beforeRowID) }
        // The limit counts conversational messages only: tool steps and notices ride
        // along, otherwise a tool-heavy turn fills the page and hides the user's messages.
        // ponytail: 2,000-row cap so a run of thousands of tool steps can't stall the read.
        var newestFirst: [StoredMobileMessage] = []
        var counted = 0
        var hasOlder = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if counted == pageSize || newestFirst.count == 2_000 { hasOlder = true; break }
            let role = String(cString: sqlite3_column_text(statement, 3))
            newestFirst.append(StoredMobileMessage(
                id: String(cString: sqlite3_column_text(statement, 1)),
                rowID: sqlite3_column_int64(statement, 0),
                conversationID: String(cString: sqlite3_column_text(statement, 2)),
                role: role,
                content: String(cString: sqlite3_column_text(statement, 4)),
                toolName: optionalText(statement, column: 5),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
            if role != "tool" && role != "system" { counted += 1 }
        }
        let page = Array(newestFirst.reversed())
        return StoredMobileMessagePage(messages: Array(page), beforeRowID: page.first?.rowID, hasOlder: hasOlder)
    }

    /// Every project conversation except the caller's own, newest first. The transcript itself is
    /// read separately with `messages`, so a listing stays cheap.
    func otherConversations(excluding conversationID: String?, projectID: String = "local-default", limit: Int = 20) -> [StoredMobileConversation] {
        conversations(excluding: conversationID, projectID: projectID, limit: limit, archived: false)
    }

    func archivedConversations(projectID: String? = nil, limit: Int = 20) -> [StoredMobileConversation] {
        conversations(excluding: nil, projectID: projectID, limit: limit, archived: true)
    }

    @discardableResult
    func setConversationArchived(_ conversationID: String, archived: Bool) -> Bool {
        guard let database, conversationStatus(conversationID) != nil else { return false }
        do {
            try execute("UPDATE conversations SET archived = ? WHERE id = ?", [archived ? "1" : "0", conversationID])
            return sqlite3_changes(database) > 0
        } catch {
            return false
        }
    }

    private func conversations(
        excluding conversationID: String?,
        projectID: String?,
        limit: Int,
        archived: Bool
    ) -> [StoredMobileConversation] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let projectFilter = projectID == nil ? "" : "project_id = ? AND "
        let sql = "SELECT id, project_id, status, updated_at, COALESCE((SELECT content FROM messages WHERE conversation_id = conversations.id AND role = 'user' ORDER BY rowid ASC LIMIT 1), ''), archived FROM conversations WHERE \(projectFilter)archived = ? ORDER BY updated_at DESC LIMIT ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        var bindIndex: Int32 = 1
        if let projectID {
            sqlite3_bind_text(statement, bindIndex, projectID, -1, transient)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, archived ? 1 : 0)
        sqlite3_bind_int(statement, bindIndex + 1, Int32(max(1, min(limit, 100))))
        var result: [StoredMobileConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            if id == conversationID { continue }
            result.append(StoredMobileConversation(
                id: id,
                projectID: String(cString: sqlite3_column_text(statement, 1)),
                status: String(cString: sqlite3_column_text(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                title: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
                archived: sqlite3_column_int(statement, 5) != 0))
        }
        return result
    }

    /// Conversations outside the currently connected projects, including the
    /// no-project workspace. Deleted project IDs remain in history and therefore
    /// fall outside `knownProjectIDs`.
    func unassignedConversations(
        excluding conversationID: String? = nil,
        knownProjectIDs: [String],
        limit: Int = 30
    ) -> [StoredMobileConversation] {
        guard let database else { return [] }
        let knownIDs = Array(Set(knownProjectIDs.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })).sorted()
        let projectFilter = knownIDs.isEmpty
            ? "WHERE archived = 0"
            : "WHERE archived = 0 AND project_id NOT IN (\(Array(repeating: "?", count: knownIDs.count).joined(separator: ",")))"
        let sql = """
            SELECT id, project_id, status, updated_at,
                COALESCE((SELECT content FROM messages WHERE conversation_id = conversations.id AND role = 'user' ORDER BY rowid ASC LIMIT 1), ''),
                archived
            FROM conversations \(projectFilter) ORDER BY updated_at DESC LIMIT ?
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        for (offset, projectID) in knownIDs.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), projectID, -1, transient)
        }
        sqlite3_bind_int(statement, Int32(knownIDs.count + 1), Int32(max(1, min(limit, 100))))
        var result: [StoredMobileConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            if id == conversationID { continue }
            result.append(StoredMobileConversation(
                id: id,
                projectID: String(cString: sqlite3_column_text(statement, 1)),
                status: String(cString: sqlite3_column_text(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                title: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
                archived: sqlite3_column_int(statement, 5) != 0))
        }
        return result
    }

    func conversationStatus(_ conversationID: String) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT status FROM conversations WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        sqlite3_bind_text(statement, 1, conversationID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private var now: String { String(Date().timeIntervalSince1970) }

    private func recoverInterruptedRuns() {
        try? transaction {
            try execute("UPDATE conversations SET status = 'interrupted', updated_at = ? WHERE status IN ('running', 'waiting')", [now])
            try execute("UPDATE pending_actions SET status = 'interrupted', updated_at = ? WHERE status IN ('running', 'waiting')", [now])
        }
    }

    /// The event log is append-only and read newest-first at most 2,000 rows per
    /// project; older rows only grew the file and every scan of it.
    private func pruneEvents() {
        try? execute("DELETE FROM events WHERE rowid <= (SELECT rowid FROM events ORDER BY rowid DESC LIMIT 1 OFFSET \(Self.retainedEvents))")
    }

    static let retainedEvents = 10_000

    private func migrate() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL)")
            try execute("INSERT INTO schema_version(version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version)")
            try execute("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS provider_accounts(id TEXT PRIMARY KEY, provider TEXT NOT NULL, model TEXT, credential_ref TEXT, created_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS oauth_accounts(id TEXT PRIMARY KEY, provider TEXT NOT NULL, account_ref TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS repositories(id TEXT PRIMARY KEY, provider TEXT, owner TEXT, name TEXT, branch TEXT, local_path TEXT, base_commit TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, project_id TEXT NOT NULL DEFAULT 'local-default', status TEXT NOT NULL, mode TEXT NOT NULL, plan_mode INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL, archived INTEGER NOT NULL DEFAULT 0)")
            try execute("CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, tool_name TEXT, created_at REAL NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            try execute("CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id)")
            try execute("CREATE TABLE IF NOT EXISTS model_context(conversation_id TEXT PRIMARY KEY, project_id TEXT NOT NULL DEFAULT 'local-default', content_json TEXT NOT NULL, updated_at REAL NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            try execute("CREATE TABLE IF NOT EXISTS queued_prompts(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, position INTEGER NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            try execute("CREATE TABLE IF NOT EXISTS pending_actions(id TEXT PRIMARY KEY, conversation_id TEXT, kind TEXT NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, conversation_id TEXT, project_id TEXT NOT NULL DEFAULT 'local-default', kind TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL)")
            try addColumnIfMissing(table: "conversations", column: "project_id", definition: "TEXT NOT NULL DEFAULT 'local-default'")
            try addColumnIfMissing(table: "conversations", column: "archived", definition: "INTEGER NOT NULL DEFAULT 0")
            try addColumnIfMissing(table: "model_context", column: "project_id", definition: "TEXT NOT NULL DEFAULT 'local-default'")
            try addColumnIfMissing(table: "events", column: "project_id", definition: "TEXT NOT NULL DEFAULT 'local-default'")
            try execute("CREATE INDEX IF NOT EXISTS idx_events_project ON events(project_id)")
            try execute("CREATE INDEX IF NOT EXISTS idx_model_context_project ON model_context(project_id, updated_at)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [String] = []) throws {
        guard let database else { throw StateStoreError.unavailable }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw StateStoreError.message(errorMessage) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else { throw StateStoreError.message(errorMessage) }
        }
        let result = sqlite3_step(statement)
        // PRAGMA assignments such as journal_mode return their resulting value
        // as one row; writes still return SQLITE_DONE.
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw StateStoreError.message(errorMessage) }
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        guard let database else { throw StateStoreError.unavailable }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StateStoreError.message(errorMessage) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1), String(cString: value) == column { return }
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private var errorMessage: String {
        guard let database, let message = sqlite3_errmsg(database) else { return "SQLite operation failed." }
        return String(cString: message)
    }

    private func optionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let statement, let value = sqlite3_column_text(statement, column) else { return nil }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }
}

private enum MobileEventPayloadSanitizer {
    static func sanitize(_ payload: [String: String]) -> [String: String] {
        payload.reduce(into: [:]) { result, item in
            result[item.key] = isSensitiveKey(item.key) || containsSecret(item.value) ? "[redacted]" : item.value
        }
    }

    /// Masks credential values in persisted text while retaining JSON structure.
    /// Event payloads use `sanitize` and discard the entire field when it contains a secret.
    static func redact(_ value: String) -> String {
        let quotedRedacted = redactQuotedValues(in: value)
        let range = NSRange(quotedRedacted.startIndex..., in: quotedRedacted)
        guard secretPattern.firstMatch(in: quotedRedacted, range: range) != nil else { return quotedRedacted }
        return secretPattern.stringByReplacingMatches(in: quotedRedacted, range: range, withTemplate: "[redacted]")
    }

    private static func containsSecret(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return quotedSecretPattern.firstMatch(in: value, range: range) != nil
            || secretPattern.firstMatch(in: value, range: range) != nil
    }

    private static func redactQuotedValues(in value: String) -> String {
        let source = value as NSString
        let range = NSRange(location: 0, length: source.length)
        let matches = quotedSecretPattern.matches(in: value, range: range)
        var result = value as NSString
        for match in matches.reversed() {
            let prefix = source.substring(with: match.range(at: 1))
            let quotedValue = source.substring(with: match.range(at: 2))
            let delimiter = quotedValue.hasPrefix("\\\"") ? "\\\"" : "\""
            result = result.replacingCharacters(
                in: match.range,
                with: prefix + delimiter + "[redacted]" + delimiter
            ) as NSString
        }
        return result as String
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        return ["apikey", "token", "accesstoken", "refreshtoken", "secret", "password", "authorization"].contains(normalized)
            || normalized.contains("credential")
    }

    private static let secretPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret|password|authorization)\s*[:=]\s*(?:bearer\s+)?(?:[^\s"\\]|\\/)+|\bBearer\s+(?:[^\s"\\]|\\/)+|\b(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{12,}\b"#
    )

    private static let quotedSecretPattern = try! NSRegularExpression(
        pattern: #"(?i)((?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret|password|authorization)(?:\\")?"?\s*[:=]\s*(?:bearer\s+)?)(?:"(?:\\.|[^"\\])*"|\\"(?:\\.|[^\\"])*\\")"#
    )
}

enum StateStoreError: LocalizedError {
    case unavailable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Local state database is unavailable."
        case .message(let value): return value
        }
    }
}
