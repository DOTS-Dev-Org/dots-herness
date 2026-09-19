package com.dots.herness.mobile

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * A prompt the phone re-runs on an interval — the mobile shape of the desktop's
 * scheduled tasks.
 *
 * Two clocks drive it. While the app is open a plain ticker fires on time. In the
 * background WorkManager takes over, and its minimum period is 15 minutes, so a
 * shorter interval only holds while the app is in front. That limit is the
 * platform's, not this code's, and the UI says so.
 */
data class AgentLoop(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val prompt: String,
    val minutes: Int,
    val enabled: Boolean = true,
    val lastRun: Long = 0,
    val lastResult: String = "",
) {
    val due get() = enabled && (lastRun == 0L || System.currentTimeMillis() - lastRun >= minutes * 60_000L)
}

/** Shared by the UI and the worker, so both see the same loops. */
class LoopStore(private val file: File) {
    fun read(): List<AgentLoop> {
        if (!file.exists()) return emptyList()
        return runCatching {
            val array = JSONArray(file.readText())
            (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                AgentLoop(
                    item.optString("id"),
                    item.optString("name"),
                    item.optString("prompt"),
                    item.optInt("minutes", 60),
                    item.optBoolean("enabled", true),
                    item.optLong("lastRun"),
                    item.optString("lastResult"),
                )
            }
        }.getOrDefault(emptyList())
    }

    fun write(loops: List<AgentLoop>) {
        file.parentFile?.mkdirs()
        file.writeText(JSONArray(loops.map {
            JSONObject()
                .put("id", it.id).put("name", it.name).put("prompt", it.prompt)
                .put("minutes", it.minutes).put("enabled", it.enabled)
                .put("lastRun", it.lastRun).put("lastResult", it.lastResult)
        }).toString())
    }
}

class LoopScheduler(private val context: Context, private val makeAgent: () -> MobileAgent) {
    private val store = LoopStore(File(context.filesDir, "herness-workspace/meta/loops.json"))
    var loops by mutableStateOf(store.read()); private set
    var running by mutableStateOf<String?>(null); private set

    fun add(name: String, prompt: String, minutes: Int) {
        loops = loops + AgentLoop(name = name.ifBlank { "Loop" }, prompt = prompt, minutes = maxOf(minutes, 1))
        store.write(loops)
        schedule()
    }

    fun remove(loop: AgentLoop) { loops = loops.filterNot { it.id == loop.id }; store.write(loops); schedule() }

    fun setEnabled(loop: AgentLoop, enabled: Boolean) {
        loops = loops.map { if (it.id == loop.id) it.copy(enabled = enabled) else it }
        store.write(loops)
        schedule()
    }

    suspend fun runDue() { loops.filter { it.due }.forEach { run(it) } }

    suspend fun run(loop: AgentLoop) {
        if (running != null) return
        running = loop.id
        try {
            val result = makeAgent().sendAndWait(loop.prompt)
            loops = store.read().map { if (it.id == loop.id) it.copy(lastRun = System.currentTimeMillis(), lastResult = result) else it }
            store.write(loops)
            notify(context, loop.name, result)
        } finally {
            running = null
        }
    }

    /** Background schedule. WorkManager will not go below 15 minutes. */
    fun schedule() {
        if (loops.none { it.enabled }) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            return
        }
        val request = PeriodicWorkRequestBuilder<LoopWorker>(15, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
    }

    companion object {
        const val WORK_NAME = "herness.loops"
        private const val CHANNEL = "herness.loops"

        fun notify(context: Context, title: String, body: String) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Loops", NotificationManager.IMPORTANCE_DEFAULT))
            if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
            val notification = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(body.take(300))
                .setStyle(NotificationCompat.BigTextStyle().bigText(body.take(1000)))
                .build()
            NotificationManagerCompat.from(context).notify(title.hashCode(), notification)
        }
    }
}

/**
 * The background half. It rebuilds the agent from scratch: a Worker is created by
 * WorkManager, so nothing from the UI process state is available to it.
 */
class LoopWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        val secure = SecureStore(context)
        val root = { File(context.filesDir, "herness-workspace/files").apply { mkdirs() }.canonicalFile }
        val scheduler = LoopScheduler(context) {
            MobileAgent({ secure.read("phone.provider").orEmpty() }, { PHONE_AGENT_SYSTEM_PROMPT }, workspaceSnapshotProvider = { AgentTools.snapshot(root()) }).apply {
                register(AgentTools.workspace(root))
                register(AgentTools.runtime(LocalShell(root), root))
                register(Plugins(root).reload())
            }
        }
        scheduler.runDue()
        return Result.success()
    }
}

/** Runs one prompt to completion and returns the agent's final text. */
suspend fun MobileAgent.sendAndWait(prompt: String): String {
    send(prompt)
    while (running) delay(250)
    return transcript.lastOrNull { it.role == "assistant" }?.text
        ?: transcript.lastOrNull { it.role == "error" }?.text
        ?: "The loop produced no output."
}
