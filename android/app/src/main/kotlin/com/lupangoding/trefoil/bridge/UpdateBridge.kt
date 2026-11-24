package com.lupangoding.trefoil.bridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.lupangoding.trefoil.core.UpdateInstaller
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** The in-app updater's side of the channel: what is installed, and the installer. */
class UpdateBridge(private val activity: Activity, messenger: BinaryMessenger) {

    private val control = MethodChannel(messenger, "trefoil/update")
    private val statusChannel = EventChannel(messenger, "trefoil/update/status")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var statusSink: EventChannel.EventSink? = null

    fun attach() {
        control.setMethodCallHandler { call, result -> onMethodCall(call.method, call.arguments, result) }
        statusChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statusSink = events
            }

            override fun onCancel(arguments: Any?) {
                statusSink = null
            }
        })
        UpdateInstaller.listener = { status, detail ->
            activity.runOnUiThread { statusSink?.success(mapOf("status" to status, "detail" to detail)) }
        }
    }

    fun detach() {
        UpdateInstaller.listener = null
        control.setMethodCallHandler(null)
        statusChannel.setStreamHandler(null)
        scope.cancel()
    }

    private fun onMethodCall(method: String, args: Any?, result: MethodChannel.Result) {
        when (method) {
            "installed" -> {
                @Suppress("DEPRECATION")
                val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
                result.success(
                    mapOf(
                        "versionName" to (info.versionName ?: ""),
                        "versionCode" to UpdateInstaller.versionCodeOf(info),
                        "abis" to Build.SUPPORTED_ABIS.toList(),
                    ),
                )
            }
            "openInstallSettings" -> result.success(openInstallSettings())
            "install" -> install(args, result)
            else -> result.notImplemented()
        }
    }

    private fun install(args: Any?, result: MethodChannel.Result) {
        val map = args as? Map<*, *>
        val path = map?.get("path") as? String
        val sha256 = map?.get("sha256") as? String
        val versionCode = (map?.get("versionCode") as? Number)?.toLong()
        if (path == null || sha256 == null || versionCode == null) {
            result.error("bad_args", "install requires {path, sha256, versionCode}", null)
            return
        }
        if (!UpdateInstaller.canInstall(activity)) {
            result.error("needs_permission", "Trefoil may not install apps yet", null)
            return
        }
        scope.launch {
            // Hashing and copying 100 MB is not main-thread work.
            val outcome = withContext(Dispatchers.IO) {
                runCatching {
                    val apk = File(path)
                    val refusal = UpdateInstaller.verify(activity, apk, sha256, versionCode)
                    if (refusal == null) UpdateInstaller.commit(activity, apk)
                    refusal
                }
            }
            outcome.fold(
                onSuccess = { refusal ->
                    if (refusal == null) result.success(null) else result.error(refusal, refusal, null)
                },
                onFailure = { result.error("install_failed", it.message ?: it.toString(), null) },
            )
        }
    }

    private fun openInstallSettings(): Boolean {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        return runCatching { activity.startActivity(intent) }.isSuccess
    }
}
