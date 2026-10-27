import Foundation
import SQLite3

/// The macOS conversation database. Conversation metadata, provider context and
/// visible transcript rows are stored separately so the UI can fetch a bounded
/// message page without decoding the rest of the history.
final class ConversationSQLiteDatabase: @unchecked Sendable {
    enum StoreError: Error {
        case sqlite(String)
        case corruptLegacyRecord
    }

    private enum Value {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null

        static func optionalText(_ value: String?) -> Self {
            value.map(Self.text) ?? .null
        }
    }

    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private let databaseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        databaseURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw StoreError.sqlite(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS store_metadata(
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS conversations(
                id TEXT PRIMARY KEY,
                workspace_path TEXT,
                projectless INTEGER NOT NULL,
                title TEXT NOT NULL,
                last_activity REAL NOT NULL,
                archived INTEGER NOT NULL,
                pinned INTEGER NOT NULL,
                blank INTEGER NOT NULL,
                state_json TEXT NOT NULL,
                model_context_json TEXT NOT NULL,
                message_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS conversation_messages(
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                message_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                changed_files_json TEXT NOT NULL DEFAULT '[]',
                payload_json TEXT NOT NULL,
                PRIMARY KEY(conversation_id, ordinal)
            );
            -- Provider context, one row per message so a run appends instead of
            -- rewriting MBs of JSON per step. Empty: the legacy model_context_json holds it.
            CREATE TABLE IF NOT EXISTS conversation_context(
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                payload_json TEXT NOT NULL,
                PRIMARY KEY(conversation_id, ordinal)
            );
            CREATE INDEX IF NOT EXISTS idx_conversations_workspace_activity
                ON conversations(workspace_path, last_activity DESC);
            CREATE INDEX IF NOT EXISTS idx_conversations_archive_activity
                ON conversations(archived, last_activity DESC);
            CREATE INDEX IF NOT EXISTS idx_messages_id
                ON conversation_messages(conversation_id, message_id);
            CREATE INDEX IF NOT EXISTS idx_messages_created
                ON conversation_messages(conversation_id, created_at);
            """)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    var fileSize: Int {
        lock.lock()
        defer { lock.unlock() }
        var total: Int64 = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? Int64) ?? 0
        for suffix in ["-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 {
                total += size
            }
        }
        return Int(min(total, Int64(Int.max)))
    }

    var legacyImportCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? scalarText("SELECT value FROM store_metadata WHERE key = 'legacy_json_imported'")) == "1"
    }

    /// Changes only when another SQLite connection commits a write. The owning
    /// ConversationStore tracks its own writes with its local revision counter.
    var dataVersion: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return (try? scalarInt("PRAGMA data_version", [])) ?? 0
    }

    func markLegacyImportCompleted() throws {
        try transaction {
            try run(
                "INSERT INTO store_metadata(key, value) VALUES('legacy_json_imported', '1') ON CONFLICT(key) DO UPDATE SET value='1'",
                []
            )
        }
    }

    /// Inserts each legacy record inside one transaction while decoding only
    /// one Conversation value at a time. Data slices share the mapped source.
    func importLegacy(records: [Data], decode: (Data) -> Conversation?) throws {
        try transaction {
            for record in records {
                guard let conversation = decode(record) else { throw StoreError.corruptLegacyRecord }
                try saveFullConversation(conversation)
            }
            try run(
                "INSERT INTO store_metadata(key, value) VALUES('legacy_json_imported', '1') ON CONFLICT(key) DO UPDATE SET value='1'",
                []
            )
        }
    }

    func headers(workspacePath: String? = nil) -> [Conversation] {
        lock.lock()
        defer { lock.unlock() }
        do {
            let sql = workspacePath == nil
                ? "SELECT state_json, last_activity, message_count FROM conversations ORDER BY last_activity DESC, id"
                : "SELECT state_json, last_activity, message_count FROM conversations WHERE workspace_path = ? ORDER BY last_activity DESC, id"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let workspacePath { try bind(.text(workspacePath), to: statement, at: 1) }
            var result: [Conversation] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw currentError() }
                guard let data = columnData(statement, at: 0),
                      var header = decodeHeader(data) else { continue }
                header.headerActivityAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                header.contentLoaded = false
                header.transcriptComplete = false
                header.messageStartIndex = 0
                header.loadedTranscriptMessageIDs = []
                result.append(header)
            }
            return result
        } catch {
            return []
        }
    }

    func loadHeaders(workspacePath: String?) -> [Conversation] {
        headers(workspacePath: ConversationStore.normalizedPath(workspacePath))
    }

    func loadAll() -> [Conversation] {
        lock.lock()
        defer { lock.unlock() }
        do {
            let statement = try prepare("SELECT id FROM conversations ORDER BY id")
            defer { sqlite3_finalize(statement) }
            var ids: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = columnText(statement, at: 0) { ids.append(id) }
            }
            return ids.compactMap { load(id: $0, allMessages: true, limit: Int.max, includeModelContext: true) }
        } catch {
            return []
        }
    }

    func load(ids: [String]) -> [Conversation] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return wanted.sorted().compactMap { load(id: $0, allMessages: true, limit: Int.max, includeModelContext: true) }
    }

    func load(id: String, allMessages: Bool = false, limit: Int = ConversationStore.defaultTranscriptPageSize, includeModelContext: Bool = true) -> Conversation? {
        lock.lock()
        defer { lock.unlock() }
        do {
            let statement = try prepare("SELECT state_json, model_context_json, last_activity, message_count FROM conversations WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(.text(id), to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let stateData = columnData(statement, at: 0),
                  var conversation = try? decoder.decode(Conversation.self, from: stateData) else { return nil }
            let contextData = columnData(statement, at: 1) ?? Data("[]".utf8)
            let activity = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            conversation.messages = []
            if includeModelContext {
                let rows = try loadContextRows(id)
                conversation.modelContext = rows.isEmpty
                    ? ((try? decoder.decode([AgentMessage].self, from: contextData)) ?? [])
                    : rows
                conversation.modelContextLoaded = true
            } else {
                conversation.modelContext = []
                conversation.modelContextLoaded = false
            }
            conversation.headerActivityAt = activity

            var rows: [(Int, ChatMessage)]
            if allMessages {
                let messages = try prepare("SELECT ordinal, payload_json FROM conversation_messages WHERE conversation_id = ? ORDER BY ordinal")
                defer { sqlite3_finalize(messages) }
                try bind(.text(id), to: messages, at: 1)
                rows = []
                while true {
                    let step = sqlite3_step(messages)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw currentError() }
                    guard let data = columnData(messages, at: 1),
                          let message = try? decoder.decode(ChatMessage.self, from: data) else { continue }
                    rows.append((Int(sqlite3_column_int64(messages, 0)), message))
                }
            } else {
                rows = try pageRows(id: id, endingBefore: Int.max, limit: limit)
            }
            conversation.messages = rows.map(\.1)
            conversation.contentLoaded = true
            conversation.messageStartIndex = rows.first?.0 ?? 0
            conversation.transcriptComplete = conversation.messageStartIndex == 0
            conversation.loadedTranscriptMessageIDs = Set(rows.map { $0.1.id })
            return conversation
        } catch {
            return nil
        }
    }

    func messagePage(id: String, endingBefore offset: Int, limit: Int = ConversationStore.defaultTranscriptPageSize) -> ConversationTranscriptPage? {
        guard limit > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        do {
            let total = try messageCount(id: id)
            let rows = try pageRows(id: id, endingBefore: offset, limit: limit)
            return ConversationTranscriptPage(messages: rows.map(\.1), startIndex: rows.first?.0 ?? 0, totalCount: total)
        } catch {
            return nil
        }
    }

    /// Newest rows before `offset`, oldest first. `limit` counts conversational
    /// messages only: tool steps and notices ride along with the page, otherwise a
    /// tool-heavy turn fills the page and hides the user/assistant messages.
    /// Caller holds `lock`.
    private func pageRows(id: String, endingBefore offset: Int, limit: Int) throws -> [(Int, ChatMessage)] {
        let statement = try prepare("SELECT ordinal, payload_json FROM conversation_messages WHERE conversation_id = ? AND ordinal < ? ORDER BY ordinal DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try bind(.text(id), to: statement, at: 1)
        try bind(.integer(Int64(max(0, offset))), to: statement, at: 2)
        // ponytail: hard row cap so a run of thousands of tool steps can't stall the read.
        try bind(.integer(2_000), to: statement, at: 3)
        let wanted = max(1, limit)
        var rows: [(Int, ChatMessage)] = []
        var counted = 0
        while counted < wanted {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw currentError() }
            guard let data = columnData(statement, at: 1),
                  let message = try? decoder.decode(ChatMessage.self, from: data) else { continue }
            rows.append((Int(sqlite3_column_int64(statement, 0)), message))
            if message.kind != .tool && message.kind != .system { counted += 1 }
        }
        return rows.reversed()
    }

    func transcript(id: String) -> [ChatMessage]? {
        load(id: id, allMessages: true, limit: Int.max, includeModelContext: false)?.messages
    }

    /// Streams through message rows without materializing the entire transcript.
    func transcriptContains(id: String, query: String, shouldCancel: @Sendable () -> Bool) -> Bool {
        guard !query.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        do {
            let statement = try prepare("SELECT payload_json FROM conversation_messages WHERE conversation_id = ? ORDER BY ordinal")
            defer { sqlite3_finalize(statement) }
            try bind(.text(id), to: statement, at: 1)
            while true {
                if shouldCancel() { return false }
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return false }
                guard step == SQLITE_ROW else { throw currentError() }
                guard let data = columnData(statement, at: 0),
                      let message = try? decoder.decode(ChatMessage.self, from: data) else { continue }
                if message.text.localizedCaseInsensitiveContains(query) { return true }
            }
        } catch {
            return false
        }
    }

    func forEachPendingPlanIntent(ids: [String], _ visit: (String, String, String) -> Void) {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let statement = try? prepare("SELECT id, state_json FROM conversations WHERE id IN (\(Self.placeholders(wanted.count)))") else { return }
        defer { sqlite3_finalize(statement) }
        for (index, id) in wanted.sorted().enumerated() { try? bind(.text(id), to: statement, at: Int32(index + 1)) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, at: 0),
                  let data = columnData(statement, at: 1),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prompts = root["pendingPrompts"] as? [[String: Any]] else { continue }
            for prompt in prompts where (prompt["planIntentResolved"] as? Bool) == false {
                guard let promptID = prompt["id"] as? String,
                      let text = prompt["text"] as? String else { continue }
                visit(id, promptID, text)
            }
        }
    }

    func forEachRecentChangedFiles(ids: [String], since cutoff: Date, _ visit: (String, String, [ChangedFile]) -> Void) {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let statement = try prepare("""
                SELECT m.conversation_id, c.title, m.changed_files_json
                FROM conversation_messages m JOIN conversations c ON c.id = m.conversation_id
                WHERE m.conversation_id IN (\(Self.placeholders(wanted.count))) AND m.created_at >= ?
                ORDER BY m.conversation_id, m.ordinal
                """)
            defer { sqlite3_finalize(statement) }
            // Bounded by the wanted chats via idx_messages_created instead of
            // scanning every stored message of every conversation.
            for (index, id) in wanted.sorted().enumerated() { try bind(.text(id), to: statement, at: Int32(index + 1)) }
            try bind(.real(cutoff.timeIntervalSince1970), to: statement, at: Int32(wanted.count + 1))
            var values: [String: (String, [ChangedFile])] = [:]
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw currentError() }
                guard let id = columnText(statement, at: 0), wanted.contains(id),
                      let title = columnText(statement, at: 1),
                      let json = columnData(statement, at: 2),
                      let files = try? decoder.decode([ChangedFile].self, from: json),
                      !files.isEmpty else { continue }
                var existing = values[id] ?? (title, [])
                existing.1.append(contentsOf: files)
                values[id] = existing
            }
            for id in values.keys.sorted() {
                guard let (title, files) = values[id] else { continue }
                visit(id, title, files)
            }
        } catch { }
    }

    /// `previous` is what the caller knows this database holds per conversation;
    /// with it only the messages and context entries that differ are written.
    @discardableResult
    func save(_ conversations: [Conversation], previous: [String: Conversation] = [:]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try transaction {
                for conversation in conversations {
                    if !conversation.contentLoaded {
                        try saveMetadata(conversation)
                    } else {
                        try saveConversation(conversation, previous: previous[conversation.id])
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(_ id: String) -> Bool {
        delete([id]) > 0
    }

    /// Removes a group of conversations in one transaction so their transcript
    /// rows are cascaded without paying for a separate SQLite commit each time.
    @discardableResult
    func delete(_ ids: [String]) -> Int {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return 0 }

        lock.lock()
        defer { lock.unlock() }
        do {
            var deletedCount = 0
            try transaction {
                // Leave room under SQLite's variable limit for older system SQLite builds.
                for start in stride(from: 0, to: uniqueIDs.count, by: 500) {
                    let end = min(start + 500, uniqueIDs.count)
                    let chunk = Array(uniqueIDs[start..<end])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    deletedCount += Int(try run(
                        "DELETE FROM conversations WHERE id IN (\(placeholders))",
                        chunk.map(Value.text)
                    ))
                }
            }
            return deletedCount
        } catch {
            return 0
        }
    }

    func deleteMessageTail(conversationID: String, startingAt ordinal: Int) {
        lock.lock()
        defer { lock.unlock() }
        try? transaction {
            try run("DELETE FROM conversation_messages WHERE conversation_id = ? AND ordinal >= ?", [.text(conversationID), .integer(Int64(max(0, ordinal)))])
            try reindexMessages(conversationID)
            try updateMessageSummary(conversationID)
        }
    }

    private func saveConversation(_ conversation: Conversation, previous: Conversation? = nil) throws {
        let messages = conversation.messages
        let previous = previous?.contentLoaded == true ? previous : nil
        var state = conversation
        state.messages = []
        state.modelContext = []
        state.contentLoaded = true
        state.transcriptComplete = false
        state.messageStartIndex = 0
        state.loadedTranscriptMessageIDs = []
        let stateData = try encoder.encode(state)
        let activity = conversation.activityDate
        try run("""
            INSERT INTO conversations(id, workspace_path, projectless, title, last_activity, archived, pinned, blank, state_json, model_context_json, message_count)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, '[]', 0)
            ON CONFLICT(id) DO UPDATE SET workspace_path=excluded.workspace_path, projectless=excluded.projectless,
                title=excluded.title, last_activity=excluded.last_activity, archived=excluded.archived,
                pinned=excluded.pinned, blank=excluded.blank, state_json=excluded.state_json,
                model_context_json=excluded.model_context_json
            """, [
                .text(conversation.id), .optionalText(Self.normalizedPath(conversation.cwd)), .integer(conversation.projectless ? 1 : 0),
                .text(conversation.title), .real(activity.timeIntervalSince1970), .integer(conversation.archived ? 1 : 0),
                .integer(conversation.pinned ? 1 : 0), .integer(conversation.blank ? 1 : 0),
                .text(String(decoding: stateData, as: UTF8.self)),
            ])
        if conversation.modelContextLoaded {
            try saveContext(conversation.id, conversation.modelContext, previous: previous?.modelContext)
        }

        if let previous, previous.transcriptComplete == conversation.transcriptComplete,
           previous.messageStartIndex == conversation.messageStartIndex,
           previous.messages.count <= messages.count,
           zip(previous.messages, messages).allSatisfy({ $0.id == $1.id }) {
            // The common case, a run appending or updating its last bubbles.
            for (old, new) in zip(previous.messages, messages) where old != new {
                try updateMessage(new, conversationID: conversation.id)
            }
            var next = Int(try scalarInt("SELECT COALESCE(MAX(ordinal), -1) FROM conversation_messages WHERE conversation_id=?", [.text(conversation.id)]) ?? -1) + 1
            for message in messages.dropFirst(previous.messages.count) {
                try insertMessage(message, conversationID: conversation.id, ordinal: next)
                next += 1
            }
        } else if conversation.transcriptComplete {
            try run("DELETE FROM conversation_messages WHERE conversation_id = ?", [.text(conversation.id)])
            for (ordinal, message) in messages.enumerated() { try insertMessage(message, conversationID: conversation.id, ordinal: ordinal) }
        } else {
            try mergeLoadedMessages(conversation)
        }
        try updateMessageSummary(conversation.id)
    }

    private func saveContext(_ id: String, _ context: [AgentMessage], previous: [AgentMessage]?) throws {
        var start = 0
        if let previous, previous.count <= context.count, context.starts(with: previous) {
            start = previous.count
        } else {
            try run("DELETE FROM conversation_context WHERE conversation_id = ?", [.text(id)])
        }
        for ordinal in start..<context.count {
            let payload = try encoder.encode(context[ordinal])
            try run("INSERT OR REPLACE INTO conversation_context(conversation_id, ordinal, payload_json) VALUES(?, ?, ?)", [
                .text(id), .integer(Int64(ordinal)), .text(String(decoding: payload, as: UTF8.self)),
            ])
        }
    }

    private func loadContextRows(_ id: String) throws -> [AgentMessage] {
        let statement = try prepare("SELECT payload_json FROM conversation_context WHERE conversation_id = ? ORDER BY ordinal")
        defer { sqlite3_finalize(statement) }
        try bind(.text(id), to: statement, at: 1)
        var rows: [AgentMessage] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw currentError() }
            guard let data = columnData(statement, at: 0) else { continue }
            rows.append(try decoder.decode(AgentMessage.self, from: data))
        }
        return rows
    }

    private func saveFullConversation(_ source: Conversation) throws {
        var conversation = source
        conversation.transcriptComplete = true
        conversation.contentLoaded = true
        try saveConversation(conversation)
    }

    private func saveMetadata(_ header: Conversation) throws {
        guard let data = try? scalarData("SELECT state_json FROM conversations WHERE id = ?", [.text(header.id)]),
              var stored = try? decoder.decode(Conversation.self, from: data) else { return }
        stored.applyMetadata(from: header)
        let stateData = try encoder.encode(stored)
        try run("""
            UPDATE conversations SET workspace_path=?, projectless=?, title=?, archived=?, pinned=?, blank=?, state_json=? WHERE id=?
            """, [
                .optionalText(Self.normalizedPath(stored.cwd)), .integer(stored.projectless ? 1 : 0), .text(stored.title),
                .integer(stored.archived ? 1 : 0), .integer(stored.pinned ? 1 : 0), .integer(stored.blank ? 1 : 0),
                .text(String(decoding: stateData, as: UTF8.self)), .text(stored.id),
            ])
    }

    private func mergeLoadedMessages(_ conversation: Conversation) throws {
        let start = max(0, conversation.messageStartIndex)
        let existingStatement = try prepare("SELECT ordinal, message_id FROM conversation_messages WHERE conversation_id=? AND ordinal>=? ORDER BY ordinal")
        defer { sqlite3_finalize(existingStatement) }
        try bind(.text(conversation.id), to: existingStatement, at: 1)
        try bind(.integer(Int64(start)), to: existingStatement, at: 2)
        var existing: [(Int, String)] = []
        while true {
            let step = sqlite3_step(existingStatement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let id = columnText(existingStatement, at: 1) else { throw currentError() }
            existing.append((Int(sqlite3_column_int64(existingStatement, 0)), id))
        }
        let currentByID = Dictionary(conversation.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var removedAny = false
        for (ordinal, id) in existing {
            if let message = currentByID[id] {
                try updateMessage(message, conversationID: conversation.id, ordinal: ordinal)
            } else {
                try run("DELETE FROM conversation_messages WHERE conversation_id=? AND ordinal=?", [.text(conversation.id), .integer(Int64(ordinal))])
                removedAny = true
            }
        }
        if removedAny { try reindexMessages(conversation.id) }

        let existingIDs = Set(existing.map(\.1))
        let maxOrdinal = Int((try scalarInt("SELECT COALESCE(MAX(ordinal), -1) FROM conversation_messages WHERE conversation_id=?", [.text(conversation.id)]) ?? -1))
        var next = maxOrdinal + 1
        for message in conversation.messages where !existingIDs.contains(message.id) {
            if let ordinal = try scalarInt("SELECT ordinal FROM conversation_messages WHERE conversation_id=? AND message_id=? LIMIT 1", [.text(conversation.id), .text(message.id)]) {
                try updateMessage(message, conversationID: conversation.id, ordinal: Int(ordinal))
            } else {
                try insertMessage(message, conversationID: conversation.id, ordinal: next)
                next += 1
            }
        }
    }

    private func insertMessage(_ message: ChatMessage, conversationID: String, ordinal: Int) throws {
        let payload = try encoder.encode(message)
        let changedFiles = try encoder.encode(message.changedFiles)
        try run("INSERT INTO conversation_messages(conversation_id, ordinal, message_id, created_at, changed_files_json, payload_json) VALUES(?, ?, ?, ?, ?, ?)", [
            .text(conversationID), .integer(Int64(ordinal)), .text(message.id), .real(message.createdAt.timeIntervalSince1970),
            .text(String(decoding: changedFiles, as: UTF8.self)), .text(String(decoding: payload, as: UTF8.self)),
        ])
    }

    private func updateMessage(_ message: ChatMessage, conversationID: String) throws {
        let payload = try encoder.encode(message)
        let changedFiles = try encoder.encode(message.changedFiles)
        try run("UPDATE conversation_messages SET created_at=?, changed_files_json=?, payload_json=? WHERE conversation_id=? AND message_id=?", [
            .real(message.createdAt.timeIntervalSince1970), .text(String(decoding: changedFiles, as: UTF8.self)),
            .text(String(decoding: payload, as: UTF8.self)), .text(conversationID), .text(message.id),
        ])
    }

    private func updateMessage(_ message: ChatMessage, conversationID: String, ordinal: Int) throws {
        let payload = try encoder.encode(message)
        let changedFiles = try encoder.encode(message.changedFiles)
        try run("UPDATE conversation_messages SET message_id=?, created_at=?, changed_files_json=?, payload_json=? WHERE conversation_id=? AND ordinal=?", [
            .text(message.id), .real(message.createdAt.timeIntervalSince1970), .text(String(decoding: changedFiles, as: UTF8.self)),
            .text(String(decoding: payload, as: UTF8.self)), .text(conversationID), .integer(Int64(ordinal)),
        ])
    }

    private func updateMessageSummary(_ id: String) throws {
        let count = try messageCount(id: id)
        let lastActivity = try scalarDouble("SELECT COALESCE(MAX(created_at), 0) FROM conversation_messages WHERE conversation_id=?", [.text(id)]) ?? 0
        try run("UPDATE conversations SET message_count=?, last_activity=? WHERE id=?", [.integer(Int64(count)), .real(lastActivity), .text(id)])
    }

    /// Counted from the rows: `updateMessageSummary` writes this into
    /// `message_count`, so reading that column back would keep it at 0 forever.
    private func messageCount(id: String) throws -> Int {
        Int(try scalarInt("SELECT COUNT(*) FROM conversation_messages WHERE conversation_id=?", [.text(id)]) ?? 0)
    }

    private func reindexMessages(_ id: String) throws {
        try run("UPDATE conversation_messages SET ordinal=-ordinal-1 WHERE conversation_id=?", [.text(id)])
        let statement = try prepare("SELECT ordinal FROM conversation_messages WHERE conversation_id=? ORDER BY ordinal DESC")
        defer { sqlite3_finalize(statement) }
        try bind(.text(id), to: statement, at: 1)
        var oldOrdinals: [Int] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw currentError() }
            oldOrdinals.append(Int(sqlite3_column_int64(statement, 0)))
        }
        for (index, oldOrdinal) in oldOrdinals.enumerated() {
            try run("UPDATE conversation_messages SET ordinal=? WHERE conversation_id=? AND ordinal=?", [.integer(Int64(index)), .text(id), .integer(Int64(oldOrdinal))])
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func normalizedPath(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private func decodeHeader(_ data: Data) -> Conversation? {
        let headerDecoder = JSONDecoder()
        headerDecoder.userInfo[ConversationStore.headersOnlyKey] = true
        return try? headerDecoder.decode(Conversation.self, from: data)
    }

    private func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw StoreError.sqlite("Database is closed") }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw StoreError.sqlite(text)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw StoreError.sqlite("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw currentError() }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Value]) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, to: statement, at: Int32(index + 1)) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw currentError() }
        return sqlite3_changes(handle)
    }

    private func bind(_ value: Value, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        switch value {
        case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, Self.transient)
        case let .integer(integer): result = sqlite3_bind_int64(statement, index, integer)
        case let .real(number): result = sqlite3_bind_double(statement, index, number)
        case .null: result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw currentError() }
    }

    private func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, at: 0)
    }

    private func scalarData(_ sql: String, _ values: [Value]) throws -> Data? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, to: statement, at: Int32(index + 1)) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnData(statement, at: 0)
    }

    private func scalarInt(_ sql: String, _ values: [Value]) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, to: statement, at: Int32(index + 1)) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarDouble(_ sql: String, _ values: [Value]) throws -> Double? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, to: statement, at: Int32(index + 1)) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func columnData(_ statement: OpaquePointer, at index: Int32) -> Data? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: length)
    }

    private func currentError() -> StoreError {
        StoreError.sqlite(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite operation failed")
    }
}
