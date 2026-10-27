package com.dots.herness.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process in the foreground while a phone-local agent run is active,
 * so leaving the app does not cancel the run before the completion notification.
 * The run itself stays in [MobileAgent]; this service only holds the process.
 */
class AgentRunService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForegroundService() requires startForeground() even when the run
        // already ended, otherwise Android 8+ crashes the process.
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: getString(R.string.agent_run_service_title)
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: getString(R.string.agent_run_service_text)
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL) ?: getString(R.string.agent_run_service_channel)
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                buildNotification(title, text, channelName),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
            )
        } catch (_: RuntimeException) {
            // Background start restrictions or an exhausted dataSync budget.
            requested = false
            foreground = false
            stopSelf()
            onForegroundLost?.invoke()
            return START_NOT_STICKY
        }
        foreground = true
        if (!requested) stopForegroundAndSelf()
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 caps dataSync at 6h per day; let the activity fallback take over.
        requested = false
        stopForegroundAndSelf()
        onForegroundLost?.invoke()
    }

    override fun onDestroy() {
        foreground = false
        super.onDestroy()
    }

    private fun stopForegroundAndSelf() {
        foreground = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(title: String, text: String, channelName: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager?.createNotificationChannel(
                NotificationChannel(CHANNEL, channelName, NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) }
            )
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setProgress(0, 0, true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        private const val CHANNEL = "herness.agent.run"
        private const val NOTIFICATION_ID = 0x4E55
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_CHANNEL = "channel"

        @Volatile private var requested = false
        @Volatile private var foreground = false

        /** True while a start was accepted and not yet stopped or refused. */
        val isActive: Boolean get() = requested

        /** Main-thread hook for when the service could not (or can no longer) stay in the foreground. */
        var onForegroundLost: (() -> Unit)? = null

        /** Returns false when Android refuses the start (e.g. app already in background). */
        fun start(context: Context): Boolean {
            requested = true
            val intent = Intent(context, AgentRunService::class.java)
                .putExtra(EXTRA_TITLE, context.getString(R.string.agent_run_service_title))
                .putExtra(EXTRA_TEXT, context.getString(R.string.agent_run_service_text))
                .putExtra(EXTRA_CHANNEL, context.getString(R.string.agent_run_service_channel))
            return try {
                ContextCompat.startForegroundService(context.applicationContext, intent)
                true
            } catch (_: RuntimeException) {
                requested = false
                onForegroundLost?.invoke()
                false
            }
        }

        fun stop(context: Context) {
            requested = false
            // Before startForeground() ran, stopService() would trip the 5s
            // contract; onStartCommand stops itself when it sees !requested.
            if (foreground) context.applicationContext.stopService(Intent(context, AgentRunService::class.java))
        }
    }
}
