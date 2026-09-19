package com.dots.herness.mobile

import android.database.sqlite.SQLiteDatabase
import java.io.File

/**
 * SQLite ships with Android, so "SQL on the phone" needs no runtime download:
 * open a database file inside the workspace and run statements against it.
 */
object LocalSql {
    const val MAXIMUM_ROWS = 500

    fun run(database: File, script: String): String {
        database.parentFile?.mkdirs()
        val handle = SQLiteDatabase.openOrCreateDatabase(database, null)
        try {
            var output = ""
            // ponytail: statements are split on a bare `;`, so a semicolon inside a
            // string literal splits too. Use one statement per call if that bites.
            script.split(";").map { it.trim() }.filter { it.isNotEmpty() }.forEach { statement ->
                val verb = statement.substringBefore(' ').lowercase()
                output = if (verb in setOf("select", "pragma", "with", "explain")) {
                    query(handle, statement)
                } else {
                    handle.execSQL(statement)
                    "Statement executed."
                }
            }
            return output
        } finally {
            handle.close()
        }
    }

    private fun query(handle: SQLiteDatabase, statement: String): String {
        handle.rawQuery(statement, null).use { cursor ->
            val columns = cursor.columnNames.toList()
            if (columns.isEmpty()) return "No columns."
            val rows = mutableListOf<String>()
            while (cursor.moveToNext() && rows.size < MAXIMUM_ROWS) {
                rows += (columns.indices).joinToString(" | ") { index ->
                    if (cursor.isNull(index)) "NULL" else cursor.getString(index) ?: "NULL"
                }
            }
            val header = listOf(columns.joinToString(" | "), columns.joinToString("-+-") { "-".repeat(maxOf(it.length, 3)) })
            val footer = if (rows.size >= MAXIMUM_ROWS) listOf("… first $MAXIMUM_ROWS rows") else emptyList()
            return (header + rows + footer).joinToString("\n")
        }
    }
}
