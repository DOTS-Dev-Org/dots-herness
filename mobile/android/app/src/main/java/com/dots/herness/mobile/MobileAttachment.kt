package com.dots.herness.mobile

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

enum class MobileAttachmentKind { IMAGE, AUDIO, VIDEO, FILE }
enum class MobileAttachmentSourceStatus { CURRENT, CHANGED, MISSING, UNREADABLE }

/** Immutable provider snapshot plus a persistable Android document URI. */
data class MobileAttachment(
    val attachmentId: String,
    val displayName: String,
    val kind: MobileAttachmentKind,
    val mimeType: String,
    val sourceLocator: String,
    val snapshotPath: String? = null,
    val contentHash: String? = null,
    val revision: Int = 0,
    val deliveredHash: String? = null,
    val sourceStatus: MobileAttachmentSourceStatus = MobileAttachmentSourceStatus.CURRENT,
) {
    fun canonicalBlock(): JSONObject = JSONObject().apply {
        put("type", "attachment")
        put("attachment_id", attachmentId)
        put("name", displayName)
        put("kind", kind.name.lowercase())
        put("mime_type", mimeType)
        put("revision", revision)
        snapshotPath?.let { put("snapshot_path", it) }
        contentHash?.let { put("content_hash", it) }
        deliveredHash?.let { put("delivered_hash", it) }
    }

    fun observe(context: Context): Observation {
        val baseline = deliveredHash ?: contentHash
        if (baseline == null) return Observation(MobileAttachmentSourceStatus.CURRENT, null)
        return runCatching {
            val hash = stableHash(context)
            Observation(if (hash.equals(baseline, ignoreCase = true)) MobileAttachmentSourceStatus.CURRENT else MobileAttachmentSourceStatus.CHANGED, hash)
        }.getOrElse { error ->
            val missing = error is java.io.FileNotFoundException || !sourceExists(context)
            Observation(if (missing) MobileAttachmentSourceStatus.MISSING else MobileAttachmentSourceStatus.UNREADABLE, null)
        }
    }

    fun stabilized(context: Context): MobileAttachment {
        if (snapshotPath != null && File(snapshotPath).exists()) return this
        val directory = File(context.filesDir, "attachment-snapshots").apply { mkdirs() }
        repeat(3) {
            val temporary = File(directory, ".${UUID.randomUUID()}.tmp")
            try {
                val before = sourceSignature(context)
                val result = copyAndHash(context, temporary)
                val after = sourceSignature(context)
                if (before != after) {
                    temporary.delete()
                    return@repeat
                }
                val extension = displayName.substringAfterLast('.', "bin").lowercase()
                val destination = File(directory, "${result.first}.$extension")
                if (!destination.exists()) temporary.renameTo(destination) else temporary.delete()
                return copy(snapshotPath = destination.absolutePath, contentHash = result.first, revision = maxOf(revision, 1), sourceStatus = MobileAttachmentSourceStatus.CURRENT)
            } catch (_: Throwable) {
                temporary.delete()
            }
        }
        return this
    }

    fun refreshed(context: Context): MobileAttachment = copy(
        snapshotPath = null,
        contentHash = null,
        revision = maxOf(revision, 1) + 1,
        deliveredHash = null,
        sourceStatus = MobileAttachmentSourceStatus.CURRENT,
    ).stabilized(context)

    fun providerData(): ByteArray? = snapshotPath?.let { path -> runCatching { File(path).takeIf { it.exists() }?.readBytes() }.getOrNull() }

    private fun sourceExists(context: Context): Boolean = runCatching {
        if (sourceLocator.startsWith("file://")) File(Uri.parse(sourceLocator).path.orEmpty()).exists()
        else context.contentResolver.openAssetFileDescriptor(Uri.parse(sourceLocator), "r")?.use { true } == true
    }.getOrDefault(false)

    private fun sourceSignature(context: Context): Pair<Long?, Long?> {
        if (sourceLocator.startsWith("file://")) {
            val file = File(Uri.parse(sourceLocator).path.orEmpty())
            return file.length() to file.lastModified()
        }
        val uri = Uri.parse(sourceLocator)
        var cursor: Cursor? = null
        return try {
            cursor = context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE, "last_modified"), null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                val modifiedIndex = cursor.getColumnIndex("last_modified")
                (if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else null) to
                    (if (modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)) cursor.getLong(modifiedIndex) else null)
            } else null to null
        } finally { cursor?.close() }
    }

    private fun copyAndHash(context: Context, destination: File): Pair<String, Long> {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1024 * 1024)
        var bytes = 0L
        val input = if (sourceLocator.startsWith("file://")) FileInputStream(File(Uri.parse(sourceLocator).path.orEmpty()))
        else context.contentResolver.openInputStream(Uri.parse(sourceLocator)) ?: throw java.io.FileNotFoundException(sourceLocator)
        input.use { stream ->
            FileOutputStream(destination).use { output ->
                while (true) {
                    val count = stream.read(buffer)
                    if (count <= 0) break
                    digest.update(buffer, 0, count)
                    output.write(buffer, 0, count)
                    bytes += count
                }
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) } to bytes
    }

    private fun stableHash(context: Context): String {
        repeat(3) {
            val before = sourceSignature(context)
            val digest = MessageDigest.getInstance("SHA-256")
            val input = if (sourceLocator.startsWith("file://")) FileInputStream(File(Uri.parse(sourceLocator).path.orEmpty()))
            else context.contentResolver.openInputStream(Uri.parse(sourceLocator)) ?: throw java.io.FileNotFoundException(sourceLocator)
            input.use { stream ->
                val buffer = ByteArray(1024 * 1024)
                while (true) {
                    val count = stream.read(buffer)
                    if (count <= 0) break
                    digest.update(buffer, 0, count)
                }
            }
            val value = digest.digest().joinToString("") { "%02x".format(it) }
            if (before == sourceSignature(context)) return value
        }
        error("The attachment changed while it was being read.")
    }

    data class Observation(val status: MobileAttachmentSourceStatus, val currentHash: String?)

    companion object {
        fun fromUri(context: Context, uri: Uri): MobileAttachment? {
            val resolver = context.contentResolver
            val mime = resolver.getType(uri) ?: "application/octet-stream"
            val name = runCatching {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)) else null
                }
            }.getOrNull() ?: uri.lastPathSegment ?: "attachment"
            val kind = when {
                mime.startsWith("image/") -> MobileAttachmentKind.IMAGE
                mime.startsWith("audio/") -> MobileAttachmentKind.AUDIO
                mime.startsWith("video/") -> MobileAttachmentKind.VIDEO
                else -> MobileAttachmentKind.FILE
            }
            return MobileAttachment(UUID.randomUUID().toString(), name, kind, mime, uri.toString())
        }
    }
}
