package com.dots.herness.mobile

import android.app.Activity
import androidx.activity.ComponentActivity
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.InstallStateUpdatedListener
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Google Play In-App Updates. Play says whether a newer build exists; our
 * check-update endpoint only decides how hard to push: a mandatory release
 * blocks the app (IMMEDIATE), anything else downloads in the background
 * (FLEXIBLE) and restarts into the new version once it is ready.
 * Builds not installed from Play simply never see an update here.
 */
class PlayUpdates(private val activity: ComponentActivity) {
    // Lazy: this object is built in the activity's field initializers, before it has a context.
    private val manager by lazy { AppUpdateManagerFactory.create(activity) }
    private var mandatory = false

    private val launcher = activity.registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        // A required update the user backed out of leaves nothing safe to run.
        if (mandatory && result.resultCode != Activity.RESULT_OK) activity.finish()
    }

    private val installListener = InstallStateUpdatedListener { state ->
        if (state.installStatus() == InstallStatus.DOWNLOADED) manager.completeUpdate()
    }

    fun checkOnLaunch() {
        activity.lifecycleScope.launch {
            mandatory = withContext(Dispatchers.IO) { runCatching { isMandatory() }.getOrDefault(false) }
            manager.appUpdateInfo.addOnSuccessListener { info ->
                if (info.updateAvailability() != UpdateAvailability.UPDATE_AVAILABLE) return@addOnSuccessListener
                val type = if (mandatory) AppUpdateType.IMMEDIATE else AppUpdateType.FLEXIBLE
                if (!info.isUpdateTypeAllowed(type)) return@addOnSuccessListener
                if (type == AppUpdateType.FLEXIBLE) manager.registerListener(installListener)
                manager.startUpdateFlowForResult(info, launcher, AppUpdateOptions.newBuilder(type).build())
            }
        }
    }

    /** Call from onResume: finishes a downloaded flexible update or resumes a blocked immediate one. */
    fun resume() {
        manager.appUpdateInfo.addOnSuccessListener { info ->
            when {
                info.installStatus() == InstallStatus.DOWNLOADED -> manager.completeUpdate()
                info.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS ->
                    manager.startUpdateFlowForResult(info, launcher, AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build())
            }
        }
    }

    fun close() = manager.unregisterListener(installListener)

    private fun isMandatory(): Boolean {
        val version = activity.packageManager.getPackageInfo(activity.packageName, 0).versionName ?: return false
        val url = URL("$ENDPOINT?platform=android&version=${URLEncoder.encode(version, "UTF-8")}")
        val connection = (url.openConnection() as HttpURLConnection).apply { connectTimeout = 10_000; readTimeout = 10_000 }
        return try {
            if (connection.responseCode !in 200..299) false
            else JSONObject(connection.inputStream.bufferedReader().use { it.readText() }).optBoolean("mandatory")
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val ENDPOINT = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/harness/check-update"
    }
}
