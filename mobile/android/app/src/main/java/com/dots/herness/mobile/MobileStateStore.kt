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
    val status: String,
    val updatedAt: Long,
)

data class StoredMobileMessage(
    val id: String,
    val conversationId: String,
    val role: String,
    val content: String,
    val toolName: String?,
    val createdAt: Long,
)

/**
 * Device-local Harness state. API keys and OAuth tokens are deliberately not
 * accepted by this class; only a secure-storage reference is persisted.
 */
class MobileStateStore(context: Context) {
    private val helper = StateDatabase(context.applicationContext)

    init {
        recoverInterruptedRuns()
    }

    fun startRun(mode: String, planMode: Boolean, prompt: String): String {
        val conversationId = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val database = helper.writableDatabase
        database.beginTransaction()
        try {
            database.insertOrThrow("conversations", null, values(
                "id" to conversationId, "status" to "running", "mode" to mode,
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

    fun appendEvent(conversationId: String?, kind: String, payload: Map<String, String>): MobileRuntimeEvent {
        val safePayload = MobileEventPayloadSanitizer.sanitize(payload)
        val event = MobileRuntimeEvent(UUID.randomUUID().toString(), conversationId, kind, safePayload, System.currentTimeMillis())
        val json = JSONObject()
        safePayload.forEach { (key, value) -> json.put(key, value) }
        val database = helper.writableDatabase
        database.beginTransaction()
        try {
            database.insertOrThrow("events", null, values(
                "id" to event.id, "conversation_id" to conversationId.orEmpty(), "kind" to kind,
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
            values("id" to "phone", "provider" to provider, "model" to model,
                "credential_ref" to safeReference, "created_at" to System.currentTimeMillis()),
            SQLiteDatabase.CONFLICT_REPLACE,
        )
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

    fun saveModelContext(conversationId: String?, content: String) {
        if (conversationId == null) return
        helper.writableDatabase.insertWithOnConflict(
            "model_context", null,
            values("conversation_id" to conversationId, "content_json" to MobileEventPayloadSanitizer.redact(content), "updated_at" to System.currentTimeMillis()),
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun saveSetting(key: String, value: String) {
        helper.writableDatabase.insertWithOnConflict(
            "settings", null, values("key" to key, "value" to value), SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun setting(key: String): String? = helper.readableDatabase.query(
        "settings", arrayOf("value"), "key = ?", arrayOf(key), null, null, null, "1",
    ).use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

    fun recentEvents(limit: Int = 500): List<MobileRuntimeEvent> = helper.readableDatabase.query(
        "events", arrayOf("id", "conversation_id", "kind", "payload_json", "created_at"),
        null, null, null, null, "rowid DESC", limit.coerceIn(1, 2_000).toString(),
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

    fun messages(conversationId: String, limit: Int = 500): List<StoredMobileMessage> = helper.readableDatabase.query(
        "messages", arrayOf("id", "conversation_id", "role", "content", "tool_name", "created_at"),
        "conversation_id = ?", arrayOf(conversationId), null, null, "rowid ASC", limit.coerceIn(1, 2_000).toString(),
    ).use { cursor ->
        buildList {
            while (cursor.moveToNext()) {
                add(StoredMobileMessage(
                    cursor.getString(0), cursor.getString(1), cursor.getString(2), cursor.getString(3),
                    cursor.getString(4).ifBlank { null }, cursor.getLong(5),
                ))
            }
        }
    }

    /**
     * Every chat except the caller's own, newest first. The transcript itself is
     * read separately with [messages], so a listing stays cheap.
     */
    fun otherConversations(excluding: String?, limit: Int = 20): List<StoredMobileConversation> =
        helper.readableDatabase.query(
            "conversations", arrayOf("id", "status", "updated_at"),
            null, null, null, null, "updated_at DESC", limit.coerceIn(1, 100).toString(),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    if (id == excluding) continue
                    add(StoredMobileConversation(id, cursor.getString(1), cursor.getLong(2)))
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
            database.execSQL("CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, status TEXT NOT NULL, mode TEXT NOT NULL, plan_mode INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            database.execSQL("CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, tool_name TEXT, created_at INTEGER NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            database.execSQL("CREATE TABLE IF NOT EXISTS model_context(conversation_id TEXT PRIMARY KEY, content_json TEXT NOT NULL, updated_at INTEGER NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE)")
            database.execSQL("CREATE TABLE IF NOT EXISTS pending_actions(id TEXT PRIMARY KEY, conversation_id TEXT, kind TEXT NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
            database.execSQL("CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, conversation_id TEXT, kind TEXT NOT NULL, payload_json TEXT NOT NULL, created_at INTEGER NOT NULL)")
        }

        override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 1) onCreate(database)
        }

        companion object { const val VERSION = 1 }
    }
}

private object MobileEventPayloadSanitizer {
    private val secretPattern = Regex("(?i)(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|password|authorization)\\s*[:=]\\s*\\S+|\\bBearer\\s+\\S+|\\b(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{12,}\\b")

    fun sanitize(payload: Map<String, String>): Map<String, String> = payload.mapValues { (key, value) ->
        if (isSensitiveKey(key)) "[redacted]" else redact(value)
    }

    fun redact(value: String): String = if (secretPattern.containsMatchIn(value)) "[redacted]" else value

    private fun isSensitiveKey(key: String): Boolean {
        val normalized = key.replace("-", "").replace("_", "").lowercase()
        return normalized in setOf("apikey", "token", "accesstoken", "refreshtoken", "secret", "password", "authorization") || normalized.contains("credential")
    }
}
