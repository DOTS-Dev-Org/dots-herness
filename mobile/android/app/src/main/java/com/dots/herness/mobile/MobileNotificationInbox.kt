package com.dots.herness.mobile

import android.content.Context
import android.text.format.DateUtils
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class MobileInboxNotification(
    val id: String,
    val kind: String,
    val title: String,
    val subtitle: String,
    val detail: String,
    val conversationId: String?,
    val projectId: String?,
    val conversationPath: String?,
    val createdAt: Long,
    val isRead: Boolean,
)

class MobileNotificationInbox private constructor(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("herness.notifications", Context.MODE_PRIVATE)
    var items by mutableStateOf(read())
        private set

    val unreadCount: Int get() = items.count { !it.isRead }

    fun append(
        kind: String,
        title: String,
        subtitle: String = "",
        detail: String = "",
        conversationId: String? = null,
        projectId: String? = null,
        conversationPath: String? = null,
        isRead: Boolean = false,
    ) {
        val compact = detail.split(Regex("\\s+")).filter(String::isNotEmpty).joinToString(" ")
        val preview = if (compact.length > 240) compact.take(240) + "…" else compact
        items = (listOf(MobileInboxNotification(UUID.randomUUID().toString(), kind, title, subtitle, preview,
            conversationId, projectId, conversationPath, System.currentTimeMillis(), isRead)) + items).take(100)
        persist()
    }

    fun markRead(id: String) {
        val index = items.indexOfFirst { it.id == id }
        if (index < 0 || items[index].isRead) return
        items = items.toMutableList().also { it[index] = it[index].copy(isRead = true) }
        persist()
    }

    fun markAllRead() {
        if (items.none { !it.isRead }) return
        items = items.map { it.copy(isRead = true) }
        persist()
    }

    fun clear() {
        if (items.isEmpty()) return
        items = emptyList()
        persist()
    }

    private fun read(): List<MobileInboxNotification> = runCatching {
        val array = JSONArray(preferences.getString("inbox.v1", "[]"))
        (0 until array.length()).mapNotNull { index -> array.optJSONObject(index)?.let { value ->
            MobileInboxNotification(
                id = value.optString("id"), kind = value.optString("kind"),
                title = value.optString("title"), subtitle = value.optString("subtitle"), detail = value.optString("detail"),
                conversationId = value.optString("conversationId").takeIf(String::isNotBlank),
                projectId = value.optString("projectId").takeIf(String::isNotBlank),
                conversationPath = value.optString("conversationPath").takeIf(String::isNotBlank),
                createdAt = value.optLong("createdAt"), isRead = value.optBoolean("isRead"),
            )
        } }.sortedByDescending { it.createdAt }.take(100)
    }.getOrDefault(emptyList())

    private fun persist() {
        val array = JSONArray()
        items.forEach { item ->
            array.put(JSONObject()
                .put("id", item.id).put("kind", item.kind).put("title", item.title)
                .put("subtitle", item.subtitle).put("detail", item.detail)
                .put("conversationId", item.conversationId).put("projectId", item.projectId)
                .put("conversationPath", item.conversationPath).put("createdAt", item.createdAt)
                .put("isRead", item.isRead))
        }
        preferences.edit().putString("inbox.v1", array.toString()).apply()
    }

    companion object {
        @Volatile private var sharedInstance: MobileNotificationInbox? = null

        fun shared(context: Context): MobileNotificationInbox = sharedInstance ?: synchronized(this) {
            sharedInstance ?: MobileNotificationInbox(context.applicationContext).also { sharedInstance = it }
        }
    }
}

@Composable
fun MobileNotificationsDialog(
    inbox: MobileNotificationInbox,
    onDismiss: () -> Unit,
    onSelect: (MobileInboxNotification) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("🔔")
                Text(stringResource(R.string.notifications_title), modifier = Modifier.weight(1f))
                if (inbox.unreadCount > 0) Text(inbox.unreadCount.toString(), color = MaterialTheme.colorScheme.primary)
            }
        },
        text = {
            Column {
                if (inbox.items.isEmpty()) {
                    Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("🔕", style = MaterialTheme.typography.headlineMedium)
                        Text(stringResource(R.string.notifications_empty_title), fontWeight = FontWeight.SemiBold)
                        Text(stringResource(R.string.notifications_empty_body), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    LazyColumn(Modifier.heightIn(max = 420.dp)) {
                        items(inbox.items, key = { it.id }) { item ->
                            Column(Modifier.fillMaxWidth().clickable { onSelect(item) }.padding(vertical = 9.dp, horizontal = 2.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        item.title,
                                        Modifier.weight(1f),
                                        style = MaterialTheme.typography.bodyLarge,
                                        fontWeight = if (item.isRead) FontWeight.Medium else FontWeight.SemiBold,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    if (!item.isRead) Text("●", color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 6.dp))
                                }
                                Text(
                                    DateUtils.getRelativeTimeSpanString(item.createdAt).toString(),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                )
                                if (item.subtitle.isNotBlank()) Text(item.subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                if (item.detail.isNotBlank()) Text(item.detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface, maxLines = 4, overflow = TextOverflow.Ellipsis)
                            }
                            HorizontalDivider()
                        }
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = inbox::markAllRead, enabled = inbox.unreadCount > 0) { Text(stringResource(R.string.notifications_mark_all_read)) }
                    TextButton(onClick = inbox::clear, enabled = inbox.items.isNotEmpty()) { Text(stringResource(R.string.notifications_clear_all), color = Color.Red) }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.intro_back)) } },
    )
}
