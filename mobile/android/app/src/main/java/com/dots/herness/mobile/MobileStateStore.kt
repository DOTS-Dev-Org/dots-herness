package com.dots.herness.mobile

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject
import java.util.UUID

data class MobileRuntimeEvent(
    val id: String,
    val conversationId: String?,
    val kind: String,
    val payload: Map<String, String>,
    val createdAt: Long,
)

data class StoredMobileConversation(
    val id: String,
    val projectId: String,
    val status: String,
    val updatedAt: Long,
    val title: String,
)

data class StoredMobileMessage(
    val id: String,
    val rowId: Long,
    val conversationId: String,
    val role: String,
    val content: String,
    val toolName: String?,
    val createdAt: Long,
)

data class StoredMobileMessagePage(
    val messages: List<StoredMobileMessage>,
    val beforeRowId: Long?,
    val hasOlder: Boolean,
)

data class StoredMobileModelContext(
    val conversationId: String,
    val projectId: String,
    val content: String,
)

/**
 * Device-local Harness state. API keys and OAuth tokens are deliberately not
 * accepted by this class; only a secure-storage reference is persisted.
 */
class MobileStateStore(context: Context) {
    private companion object { const val RETAINED_EVENTS = 10_000 }

    private val helper = StateDatabase(context.applicationContext)

    init {
        recoverInterruptedRuns()
        // The event log is append-only and read newest-first at most 2,000 rows per
        // project; older rows only grew the file and every scan of it.
        helper.writableDatabase.execSQL(
            "DELETE FROM events WHERE rowid <= (SELECT rowid FROM events ORDER BY rowid DESC LIMIT 1 OFFSET $RETAINED_EVENTS)",
        )
    }

    fun startRun(mode: String, planMode: Boolean, prompt: String, projectId: String = "local-default"): String {
        val conversationId = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val database = helper.writableDatabase
        database.beginTransaction()
        try {
            database.insertOrThrow("conversations", null, values(
                "id" to conversationId, "project_id" to projectId, "status" to "running", "mode" to mode,
                "plan_mode" to if (planMode) 1 else 0, "created_at" to now, "updated_at" to now,
            ))
            database.insertOrThrow("pending_actions", null, values(
                "id" to UUID.randomUUID().toString(), "conversation_id" to conversationId,
                "kind" to "run", "payload_json" to "{}", "status" to "running",
                "created_at" to now, "updated_at" to now,
            ))
            database.insertOrThrow("messages", null, values(
                "id" to UUID.randomUUID().toString(), "conversation_id" to conversationId,
                "role" to "user", "content" to MobileEventPayloadSanitizer.redact(prompt), "created_at" to now,
            ))
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
        return conversationId
    }

    /** Persist a conversation before classifying or starting its first prompt. */
    fun reserveConversation(projectId: String = "local-default"): String {
        val conversationId = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val database = helper.writableDatabase
        database.beginTransaction()
        try {
            database.insertOrThrow("conversations", null, values(
                "id" to conversationId, "project_id" to projectId, "status" to "queued", "mode" to "agent",
                "plan_mode" to 0, "created_at" to now, "updated_at" to now,
            ))
            database.insertOrThrow("model_context", null, values(
                "conversation_id" to conversationId, "project_id" to projectId,
                "content_json" to "{\"version\":3,\"messages\":[]}", "updated_at" to now,
            ))
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
        return conversationId
    }

    /** Atomically creates a conversation and durably accepts its first queued prompt. */
    fun reserveConversation(projectId: String, queuedPromptId: String, queuedPromptPayload: String, snapshot: String): String? {
        val conversationId = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val database = helper.writableDatabase
        return try {
            database.beginTransaction()
            try {
                database.insertOrThrow("conversations", null, values(
                    "id" to conversationId, "project_id" to projectId, "status" to "queued", "mode" to "agent",
                    "plan_mode" to 0, "created_at" to now, "updated_at" to now,
                ))
                database.insertOrThrow("model_context", null, values(
                    "conversation_id" to conversationId, "project_id" to projectId,
                    "content_json" to MobileEventPayloadSanitizer.redact(snapshot), "updated_at" to now,
                ))
                database.insertOrThrow("queued_prompts", null, values(
                    "id" to queuedPromptId, "conversation_id" to conversationId, "position" to 0,
                    "payload_json" to MobileEventPayloadSanitizer.redact(queuedPromptPayload), "created_at" to now,
                ))
                database.setTransactionSuccessful()
                conversationId
            } finally {
                database.endTransaction()
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Atomically moves a queued prompt into the transcript and active run. */
    fun beginReservedRun(
        conversationId: String,
        mode: String,
        planMode: Boolean,
        prompt: String,
        consumedPromptId: String? = null,
        projectId: String = "local-default",
        snapshot: String? = null,
        queuedPrompts: List<Pair<String, String>>? = null,
    ): Boolean {
        val now = System.currentTimeMillis()
        val database = helper.writableDatabase
        return try {
            database.beginTransaction()
            try {
            database.execSQL("UPDATE conversations SET status = 'running', mode = ?, plan_mode = ?, updated_at = ? WHERE id = ?", arrayOf(mode, if (planMode) 1 else 0, now, conversationId))
            database.insertOrThrow("pending_actions", null, values(
                "id" to UUID.randomUUID().toString(), "conversation_id" to conversationId,
                "kind" to "run", "payload_json" to "{}", "status" to "running",
                "created_at" to now, "updated_at" to now,
            ))
            database.insertOrThrow("messages", null, values(
                "id" to UUID.randomUUID().toString(), "conversation_id" to conversationId,
                "role" to "user", "content" to MobileEventPayloadSanitizer.redact(prompt), "created_at" to now,
            ))
            if (consumedPromptId != null) database.delete("queued_prompts", "id = ? AND conversation_id = ?", arrayOf(consumedPromptId, conversationId))
            if (snapshot != null) {
                database.insertWithOnConflict("model_context", null, values(
                    "conversation_id" to conversationId, "project_id" to projectId,
                    "content_json" to MobileEventPayloadSanitizer.redact(snapshot), "updated_at" to now,
                ), SQLiteDatabase.CONFLICT_REPLACE)
            }
            if (queuedPrompts != null) {
                database.delete("queued_prompts", "conversation_id = ?", arrayOf(conversationId))
                queuedPrompts.forEachIndexed { position, (id, payload) ->
                    database.insertOrThrow("queued_prompts", null, values(
                        "id" to id, "conversation_id" to conversationId, "position" to position,
                        "payload_json" to MobileEventPayloadSanitizer.redact(payload), "created_at" to now,
                    ))
                }
            }
                database.setTransactionSuccessful()
                true
            } finally {
                database.endTransaction()
            }
        } catch (_: Exception) {
            false
        }
    }

    fun appendMessage(conversationId: String?, role: String, content: String, toolName: String? = null) {
        if (conversationId == null) return
        val database = helper.writableDatabase
        database.beginTransaction()
        try {
            database.insertOrThrow("messages", null, values(
                "id" to UUID.randomUUID().toString(), "conversation_id" to conversationId,
                "role" to role, "content" to MobileEventPayloadSanitizer.redact(content), "tool_name" to toolName.orEmpty(),
                "created_at" to System.currentTimeMillis(),
            ))
            database.execSQL("UPDATE conversations SET updated_at = ? WHERE id = ?", arrayOf(System.currentTimeMillis(), conversationId))
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    fun appendEvent(conversationId: String?, projectId: String = "local-default", kind: String, payload: Map<String, String>): MobileRuntimeEvent {
        val safePayload = MobileEventPayloadSanitizer.sanitize(payload)
        val event = MobileRuntimeEvent(UUID.randomUUID().toString(), conversationId, kind, safePayload, System.currentTimeMillis())
        val json = JSONObject()
        safePayload.forEach { (key, value) -> json.put(key, value) }
        val database = helper.writableDatabase
        database.beginTransaction()
        try {
            database.insertOrThrow("events", null, values(
                "id" to event.id, "conversation_id" to conversationId.orEmpty(), "project_id" to projectId, "kind" to kind,
                "payload_json" to json.toString(), "created_at" to event.createdAt,
            ))
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
        return event
    }

    fun finishRun(conversationId: String?, status: String) {
        if (conversationId == null) return
        val database = helper.writableDatabase
        database.beginTransaction()
        try {
            val now = System.currentTimeMillis()
            database.execSQL("UPDATE conversations SET status = ?, updated_at = ? WHERE id = ?", arrayOf(status, now, conversationId))
            database.execSQL("UPDATE pending_actions SET status = ?, updated_at = ? WHERE conversation_id = ? AND status = 'running'", arrayOf(status, now, conversationId))
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    fun savePendingAction(id: String, conversationId: String?, kind: String, payload: Map<String, String>, status: String) {
        if (conversationId == null) return
        val json = JSONObject()
        MobileEventPayloadSanitizer.sanitize(payload).forEach { (key, value) -> json.put(key, value) }
        val database = helper.writableDatabase
        database.beginTransaction()
        try {
            database.insertWithOnConflict(
                "pending_actions", null,
                values("id" to id, "conversation_id" to conversationId, "kind" to kind,
                    "payload_json" to json.toString(), "status" to status,
                    "created_at" to System.currentTimeMillis(), "updated_at" to System.currentTimeMillis()),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    fun resolvePendingAction(id: String, status: String) {
        helper.writableDatabase.execSQL("UPDATE pending_actions SET status = ?, updated_at = ? WHERE id = ?", arrayOf(status, System.currentTimeMillis(), id))
    }

    fun saveProvider(provider: String, model: String, credentialReference: String) {
        val safeReference = credentialReference.takeIf { it.startsWith("keystore:") } ?: "[redacted]"
        helper.writableDatabase.insertWithOnConflict(
            "provider_accounts", null,
            values("id" to "phone.$provider", "provider" to provider, "model" to model,
                "credential_ref" to safeReference, "created_at" to System.currentTimeMillis()),
            SQLiteDatabase.CONFLICT_REPLACE,
        )
        helper.writableDatabase.delete("provider_accounts", "id = ?", arrayOf("phone"))
    }

    fun saveOAuth(provider: String, accountReference: String) {
        val safeReference = accountReference.takeIf { it.startsWith("keystore:") } ?: "[redacted]"
        helper.writableDatabase.insertWithOnConflict(
            "oauth_accounts", null,
            values("id" to provider, "provider" to provider, "account_ref" to safeReference,
                "created_at" to System.currentTimeMillis(), "updated_at" to System.currentTimeMillis()),
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun saveRepository(repository: RepoCoordinates, localPath: String = "workspace", baseCommit: String? = null) {
        helper.writableDatabase.insertWithOnConflict(
            "repositories", null,
            values("id" to "github:${repository.slug}", "provider" to "github", "owner" to repository.owner,
                "name" to repository.repository, "branch" to repository.branch, "local_path" to localPath,
                "base_commit" to baseCommit.orEmpty(), "created_at" to System.currentTimeMillis(),
                "updated_at" to System.currentTimeMillis()),
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun saveModelContext(
        conversationId: String?,
        projectId: String = "local-default",
        content: String,
        queuedPrompts: List<Pair<String, String>>? = null,
    ): Boolean {
        if (conversationId == null) return false
        val database = helper.writableDatabase
        val now = System.currentTimeMillis()
        return try {
            database.beginTransaction()
            try {
                database.insertWithOnConflict(
                "model_context", null,
                values("conversation_id" to conversationId, "project_id" to projectId, "content_json" to MobileEventPayloadSanitizer.redact(content), "updated_at" to now),
                SQLiteDatabase.CONFLICT_REPLACE,
                )
                if (queuedPrompts != null) {
                    database.delete("queued_prompts", "conversation_id = ?", arrayOf(conversationId))
                    queuedPrompts.forEachIndexed { position, (id, payload) ->
                        database.insertOrThrow("queued_prompts", null, values(
                            "id" to id, "conversation_id" to conversationId, "position" to position,
                            "payload_json" to MobileEventPayloadSanitizer.redact(payload), "created_at" to now,
                        ))
                    }
                }
                database.execSQL("UPDATE conversations SET updated_at = ? WHERE id = ?", arrayOf(now, conversationId))
                database.setTransactionSuccessful()
                true
            } finally {
                database.endTransaction()
            }
        } catch (_: Exception) {
            false
        }
    }

    fun queuedPromptPayloads(conversationId: String): List<Pair<String, String>> = helper.readableDatabase.query(
        "queued_prompts", arrayOf("id", "payload_json"), "conversation_id = ?", arrayOf(conversationId), null, null, "position ASC",
    ).use { cursor ->
        buildList {
            while (cursor.moveToNext()) add(cursor.getString(0) to cursor.getString(1))
        }
    }

    fun latestModelContext(projectId: String = "local-default"): StoredMobileModelContext? = helper.readableDatabase.query(
        "model_context", arrayOf("conversation_id", "project_id", "content_json"),
        "project_id = ?", arrayOf(projectId), null, null, "updated_at DESC", "1",
    ).use { cursor ->
        if (cursor.moveToFirst()) StoredMobileModelContext(cursor.getString(0), cursor.getString(1), cursor.getString(2)) else null
    }

    fun modelContext(conversationId: String): StoredMobileModelContext? = helper.readableDatabase.query(
        "model_context", arrayOf("conversation_id", "project_id", "content_json"),
        "conversation_id = ?", arrayOf(conversationId), null, null, null, "1",
    ).use { cursor ->
        if (cursor.moveToFirst()) StoredMobileModelContext(cursor.getString(0), cursor.getString(1), cursor.getString(2)) else null
    }

    fun saveSetting(key: String, value: String) {
        helper.writableDatabase.insertWithOnConflict(
            "settings", null, values("key" to key, "value" to value), SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun setting(key: String): String? = helper.readableDatabase.query(
        "settings", arrayOf("value"), "key = ?", arrayOf(key), null, null, null, "1",
    ).use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

    fun recentEvents(projectId: String = "local-default", limit: Int = 500): List<MobileRuntimeEvent> = helper.readableDatabase.query(
        "events", arrayOf("id", "conversation_id", "kind", "payload_json", "created_at"),
        "project_id = ?", arrayOf(projectId), null, null, "rowid DESC", limit.coerceIn(1, 2_000).toString(),
    ).use { cursor ->
        val result = mutableListOf<MobileRuntimeEvent>()
        while (cursor.moveToNext()) {
            val payloadObject = runCatching { JSONObject(cursor.getString(3)) }.getOrElse { JSONObject() }
            val payload = payloadObject.keys().asSequence().associateWith { key -> payloadObject.optString(key) }
            result += MobileRuntimeEvent(
                cursor.getString(0), cursor.getString(1).ifBlank { null }, cursor.getString(2),
                payload, cursor.getLong(4),
            )
        }
        result.asReversed()
    }

    fun messages(conversationId: String, limit: Int = 10): List<StoredMobileMessage> =
        messagePage(conversationId, limit = limit).messages

    fun messagePage(conversationId: String, beforeRowId: Long? = null, limit: Int = 10): StoredMobileMessagePage {
        val pageSize = limit.coerceIn(1, 2_000)
        val selection = if (beforeRowId == null) "conversation_id = ?" else "conversation_id = ? AND rowid < ?"
        // The limit counts conversational messages only: tool steps and notices ride
        // along, otherwise a tool-heavy turn fills the page and hides the user's messages.
        // ponytail: 2,000-row cap so a run of thousands of tool steps can't stall the read.
        var hasOlder = false
        val newestFirst = helper.readableDatabase.query(
            "messages", arrayOf("rowid", "id", "conversation_id", "role", "content", "tool_name", "created_at"),
            selection, if (beforeRowId == null) arrayOf(conversationId) else arrayOf(conversationId, beforeRowId.toString()),
            null, null, "rowid DESC",
        ).use { cursor ->
            buildList {
                var counted = 0
                while (cursor.moveToNext()) {
                    if (counted == pageSize || size == 2_000) { hasOlder = true; break }
                    val message = StoredMobileMessage(
                        cursor.getString(1), cursor.getLong(0), cursor.getString(2), cursor.getString(3), cursor.getString(4),
                        cursor.getString(5).ifBlank { null }, cursor.getLong(6),
                    )
                    add(message)
                    if (message.role != "tool" && message.role != "system") counted++
                }
            }
        }
        val page = newestFirst.asReversed()
        return StoredMobileMessagePage(page, page.firstOrNull()?.rowId, hasOlder)
    }

    /**
     * Every project conversation except the caller's own, newest first. The transcript itself is
     * read separately with [messages], so a listing stays cheap.
     */
    fun otherConversations(excluding: String?, projectId: String = "local-default", limit: Int = 20): List<StoredMobileConversation> =
        helper.readableDatabase.rawQuery(
            """SELECT c.id, c.project_id, c.status, c.updated_at,
                COALESCE((SELECT m.content FROM messages m WHERE m.conversation_id = c.id AND m.role = 'user' ORDER BY m.rowid ASC LIMIT 1), '')
                FROM conversations c WHERE c.project_id = ? ORDER BY c.updated_at DESC LIMIT ?""",
            arrayOf(projectId, limit.coerceIn(1, 100).toString()),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    if (id == excluding) continue
                    add(StoredMobileConversation(id, cursor.getString(1), cursor.getString(2), cursor.getLong(3), cursor.getString(4)))
                }
            }
        }

    fun conversationStatus(conversationId: String): String? = helper.readableDatabase.query(
        "conversations", arrayOf("status"), "id = ?", arrayOf(conversationId), null, null, null, "1",
    ).use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

    private fun recoverInterruptedRuns() {
        val database = helper.writableDatabase
        val now = System.currentTimeMillis()
        database.beginTransaction()
        try {
            database.execSQL("UPDATE conversations SET status = 'interrupted', updated_at = ? WHERE status IN ('running', 'waiting')", arrayOf(now))
            database.execSQL("UPDATE pending_actions SET status = 'interrupted', updated_at = ? WHERE status IN ('running', 'waiting')", arrayOf(now))
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    private fun values(vararg entries: Pair<String, Any?>) = ContentValues().apply {
        entries.forEach { (key, value) ->
            when (value) {
                null -> putNull(key)
                is String -> put(key, value)
                is Int -> put(key, value)
                is Long -> put(key, value)
                is Boolean -> put(key, if (value) 1 else 0)
            }
        }
    }

    private class StateDatabase(context: Context) : SQLiteOpenHelper(context, "herness_state.db", null, VERSION) {
        override fun onCreate(database: SQLiteDatabase) {
            database.execSQL("CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL)")
            database.execSQL("INSERT INTO schema_version(version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version)")
            database.execSQL("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            database.execSQL("CREATE TABLE IF NOT EXISTS provider_accounts(id TEXT PRIMARY KEY, provider TEXT NOT NULL, model TEXT, credential_ref TEXT, created_at INTEGER NOT NULL)")
            database.execSQL("CREATE TABLE IF NOT EXISTS oauth_accounts(id TEXT PRIMARY KEY, provider TEXT NOT NULL, account_ref TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            database.execSQL("CREATE TABLE IF NOT EXISTS repositories(id TEXT PRIMARY KEY, provider TEXT, owner TEXT, name TEXT, branch TEXT, local_path TEXT, base_commit TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            database.execSQL("CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, project_id TEXT NOT NULL DEFAULT 'local-default', status TEXT NOT NULL, mode TEXT NOT NULL, plan_mode INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            database.execSQL("CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, tool_name TEXT, created_at INTEGER NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            database.execSQL("CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id)")
            database.execSQL("CREATE TABLE IF NOT EXISTS model_context(conversation_id TEXT PRIMARY KEY, project_id TEXT NOT NULL DEFAULT 'local-default', content_json TEXT NOT NULL, updated_at INTEGER NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            database.execSQL("CREATE TABLE IF NOT EXISTS queued_prompts(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, position INTEGER NOT NULL, payload_json TEXT NOT NULL, created_at INTEGER NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            database.execSQL("CREATE TABLE IF NOT EXISTS pending_actions(id TEXT PRIMARY KEY, conversation_id TEXT, kind TEXT NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            database.execSQL("CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, conversation_id TEXT, project_id TEXT NOT NULL DEFAULT 'local-default', kind TEXT NOT NULL, payload_json TEXT NOT NULL, created_at INTEGER NOT NULL)")
            createLookupIndexes(database)
        }

        /** recentEvents and latestModelContext filter by project; without these both scan the table. */
        private fun createLookupIndexes(database: SQLiteDatabase) {
            database.execSQL("CREATE INDEX IF NOT EXISTS idx_events_project ON events(project_id)")
            database.execSQL("CREATE INDEX IF NOT EXISTS idx_model_context_project ON model_context(project_id, updated_at)")
        }

        override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                runCatching { database.execSQL("ALTER TABLE conversations ADD COLUMN project_id TEXT NOT NULL DEFAULT 'local-default'") }
                runCatching { database.execSQL("ALTER TABLE model_context ADD COLUMN project_id TEXT NOT NULL DEFAULT 'local-default'") }
            }
            if (oldVersion < 3) {
                runCatching { database.execSQL("ALTER TABLE events ADD COLUMN project_id TEXT NOT NULL DEFAULT 'local-default'") }
            }
            if (oldVersion < 4) {
                database.execSQL("CREATE TABLE IF NOT EXISTS queued_prompts(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, position INTEGER NOT NULL, payload_json TEXT NOT NULL, created_at INTEGER NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            }
            if (oldVersion < 5) {
                database.execSQL("CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id)")
            }
            if (oldVersion < 6) createLookupIndexes(database)
        }

        companion object { const val VERSION = 6 }
    }
}

internal object MobileEventPayloadSanitizer {
    private val secretPattern = Regex("""(?i)(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret|password|authorization)\s*[:=]\s*(?:bearer\s+)?(?:[^\s"\\]|\\/)+|\bBearer\s+(?:[^\s"\\]|\\/)+|\b(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{12,}\b""")
    private val quotedSecretPattern = Regex("""(?i)((?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret|password|authorization)(?:\\")?"?\s*[:=]\s*(?:bearer\s+)?)(?:"(?:\\.|[^"\\])*"|\\"(?:\\.|[^\\"])*\\")""")

    fun sanitize(payload: Map<String, String>): Map<String, String> = payload.mapValues { (key, value) ->
        if (isSensitiveKey(key) || containsSecret(value)) "[redacted]" else value
    }

    /** Masks credential values in persisted text while retaining JSON structure. */
    fun redact(value: String): String = secretPattern.replace(redactQuotedValues(value), "[redacted]")

    private fun containsSecret(value: String): Boolean =
        quotedSecretPattern.containsMatchIn(value) || secretPattern.containsMatchIn(value)

    private fun redactQuotedValues(value: String): String = quotedSecretPattern.replace(value) { match ->
        val prefix = match.groups[1]?.value.orEmpty()
        val quotedValue = match.value.substring(prefix.length)
        val delimiter = if (quotedValue.startsWith("\\\"")) "\\\"" else "\""
        "$prefix$delimiter[redacted]$delimiter"
    }

    private fun isSensitiveKey(key: String): Boolean {
        val normalized = key.replace("-", "").replace("_", "").lowercase()
        return normalized in setOf("apikey", "token", "accesstoken", "refreshtoken", "secret", "password", "authorization") || normalized.contains("credential")
    }
}
