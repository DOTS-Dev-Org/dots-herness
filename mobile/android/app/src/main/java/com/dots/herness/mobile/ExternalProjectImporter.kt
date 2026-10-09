package com.dots.herness.mobile

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Reads a user-selected SAF directory into a normal phone-local project. */
internal object ExternalProjectImporter {
    fun displayName(context: Context, treeUri: Uri): String = runCatching {
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
        context.contentResolver.query(
            rootUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0)?.trim().orEmpty() else ""
        }.orEmpty().ifBlank { "Imported project" }
    }.getOrDefault("Imported project")

    suspend fun copySelectedFolder(context: Context, treeUri: Uri, destination: File) = withContext(Dispatchers.IO) {
        val base = destination.canonicalFile
        if (!base.exists() && !base.mkdirs()) throw IOException("The project folder could not be created.")
        require(base.isDirectory) { "The project path is not a folder." }

        val resolver = context.applicationContext.contentResolver
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
        val basePath = base.path + File.separator

        suspend fun copyChildren(parentUri: Uri, targetDirectory: File) {
            currentCoroutineContext().ensureActive()
            val parentId = DocumentsContract.getDocumentId(parentUri)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            val cursor = resolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                ),
                null,
                null,
                null,
            ) ?: throw IOException("The selected folder could not be read.")

            cursor.use { rows ->
                val idColumn = rows.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameColumn = rows.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeColumn = rows.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                while (rows.moveToNext()) {
                    currentCoroutineContext().ensureActive()
                    val id = rows.getString(idColumn)
                    val name = rows.getString(nameColumn)?.trim().orEmpty()
                    val mime = rows.getString(mimeColumn)
                    require(name.isNotBlank() && name != "." && name != ".." && '/' !in name && '\\' !in name) {
                        "The selected folder contains an unsupported file name."
                    }
                    val target = File(targetDirectory, name).canonicalFile
                    require(target.path.startsWith(basePath)) { "The selected folder contains an unsafe path." }
                    if (target.exists()) throw IOException("Duplicate item name while importing: $name")
                    val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        if (!target.mkdirs() && !target.isDirectory) throw IOException("Folder could not be imported: $name")
                        copyChildren(childUri, target)
                    } else {
                        val temporary = File(targetDirectory, ".${name}.herness-import")
                        try {
                            val input = resolver.openInputStream(childUri) ?: throw IOException("File could not be read: $name")
                            input.use { source -> FileOutputStream(temporary).use { output -> source.copyTo(output) } }
                            if (!temporary.renameTo(target)) throw IOException("File could not be saved: $name")
                        } catch (error: Throwable) {
                            temporary.delete()
                            throw error
                        }
                    }
                }
            }
        }

        copyChildren(rootUri, base)
    }
}
