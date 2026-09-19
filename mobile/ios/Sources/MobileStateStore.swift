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
    let conversationID: String
    let role: String
    let content: String
    let toolName: String?
    let createdAt: Date
}

struct StoredMobileConversation: Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let updatedAt: Date
}

/// The on-device state boundary. Credentials never cross this type: SQLite
/// stores only a keychain reference such as `keychain:phone.provider`.
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
            try execute("PRAGMA foreign_keys = ON")
            try migrate()
            recoverInterruptedRuns()
        } catch {
            // A broken state file must not prevent the app from opening. The
            // next write will surface the failure through the runtime event.
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func startRun(mode: String, planMode: Bool, prompt: String) -> String {
        let conversationID = UUID().uuidString
        let actionID = UUID().uuidString
        do {
            try transaction {
                try execute("INSERT INTO conversations(id, status, mode, plan_mode, created_at, updated_at) VALUES(?, 'running', ?, ?, ?, ?)", [conversationID, mode, planMode ? "1" : "0", now, now])
                try execute("INSERT INTO pending_actions(id, conversation_id, kind, payload_json, status, created_at, updated_at) VALUES(?, ?, 'run', '{}', 'running', ?, ?)", [actionID, conversationID, now, now])
                try execute("INSERT INTO messages(id, conversation_id, role, content, created_at) VALUES(?, ?, 'user', ?, ?)", [UUID().uuidString, conversationID, MobileEventPayloadSanitizer.redact(prompt), now])
            }
        } catch {
            // Runtime continues in memory if persistence is unavailable.
        }
        return conversationID
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

    func appendEvent(conversationID: String?, kind: String, payload: [String: String]) -> MobileRuntimeEvent {
        let safePayload = MobileEventPayloadSanitizer.sanitize(payload)
        let event = MobileRuntimeEvent(id: UUID().uuidString, conversationID: conversationID, kind: kind, payload: safePayload, createdAt: Date())
        let data = (try? JSONEncoder().encode(safePayload)) ?? Data("{}".utf8)
        do {
            try transaction {
                try execute("INSERT INTO events(id, conversation_id, kind, payload_json, created_at) VALUES(?, ?, ?, ?, ?)", [event.id, conversationID ?? "", kind, String(decoding: data, as: UTF8.self), String(event.createdAt.timeIntervalSince1970)])
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
        do {
            try execute("INSERT INTO provider_accounts(id, provider, model, credential_ref, created_at) VALUES('phone', ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, model=excluded.model, credential_ref=excluded.credential_ref", [provider, model, safeReference, now])
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

    func saveModelContext(conversationID: String?, content: String) {
        guard let conversationID else { return }
        try? execute("INSERT INTO model_context(conversation_id, content_json, updated_at) VALUES(?, ?, ?) ON CONFLICT(conversation_id) DO UPDATE SET content_json=excluded.content_json, updated_at=excluded.updated_at", [conversationID, MobileEventPayloadSanitizer.redact(content), now])
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

    func recentEvents(limit: Int = 500) -> [MobileRuntimeEvent] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT id, conversation_id, kind, payload_json, created_at FROM events ORDER BY rowid DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 2_000))))
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

    func messages(conversationID: String, limit: Int = 500) -> [StoredMobileMessage] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT id, conversation_id, role, content, tool_name, created_at FROM messages WHERE conversation_id = ? ORDER BY rowid ASC LIMIT ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        sqlite3_bind_text(statement, 1, conversationID, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 2_000))))
        var result: [StoredMobileMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(StoredMobileMessage(
                id: String(cString: sqlite3_column_text(statement, 0)),
                conversationID: String(cString: sqlite3_column_text(statement, 1)),
                role: String(cString: sqlite3_column_text(statement, 2)),
                content: String(cString: sqlite3_column_text(statement, 3)),
                toolName: optionalText(statement, column: 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))))
        }
        return result
    }

    /// Every chat except the caller's own, newest first. The transcript itself is
    /// read separately with `messages`, so a listing stays cheap.
    func otherConversations(excluding conversationID: String?, limit: Int = 20) -> [StoredMobileConversation] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT id, status, updated_at FROM conversations ORDER BY updated_at DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 100))))
        var result: [StoredMobileConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            if id == conversationID { continue }
            result.append(StoredMobileConversation(
                id: id,
                status: String(cString: sqlite3_column_text(statement, 1)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))))
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

    private func migrate() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL)")
            try execute("INSERT INTO schema_version(version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version)")
            try execute("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS provider_accounts(id TEXT PRIMARY KEY, provider TEXT NOT NULL, model TEXT, credential_ref TEXT, created_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS oauth_accounts(id TEXT PRIMARY KEY, provider TEXT NOT NULL, account_ref TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS repositories(id TEXT PRIMARY KEY, provider TEXT, owner TEXT, name TEXT, branch TEXT, local_path TEXT, base_commit TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, status TEXT NOT NULL, mode TEXT NOT NULL, plan_mode INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, tool_name TEXT, created_at REAL NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            try execute("CREATE TABLE IF NOT EXISTS model_context(conversation_id TEXT PRIMARY KEY, content_json TEXT NOT NULL, updated_at REAL NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            try execute("CREATE TABLE IF NOT EXISTS pending_actions(id TEXT PRIMARY KEY, conversation_id TEXT, kind TEXT NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, conversation_id TEXT, kind TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL)")
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
            result[item.key] = isSensitiveKey(item.key) ? "[redacted]" : redact(item.value)
        }
    }

    static func redact(_ value: String) -> String { containsSecret(value) ? "[redacted]" : value }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        return ["apikey", "token", "accesstoken", "refreshtoken", "secret", "password", "authorization"].contains(normalized)
            || normalized.contains("credential")
    }

    private static func containsSecret(_ value: String) -> Bool {
        value.range(of: #"(?i)(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|password|authorization)\s*[:=]\s*\S+|\bBearer\s+\S+|\b(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{12,}\b"#, options: .regularExpression) != nil
    }
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
