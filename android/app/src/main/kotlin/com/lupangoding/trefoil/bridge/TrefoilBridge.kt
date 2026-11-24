package com.lupangoding.trefoil.bridge

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.Manifest
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import com.lupangoding.trefoil.core.AlwaysOn
import com.lupangoding.trefoil.core.AmneziaRuntime
import com.lupangoding.trefoil.core.AppPrefs
import com.lupangoding.trefoil.core.AutoStart
import com.lupangoding.trefoil.core.BackupCrypto
import com.lupangoding.trefoil.core.LibboxRuntime
import com.lupangoding.trefoil.core.ServerUsage
import com.lupangoding.trefoil.core.ServiceState
import com.lupangoding.trefoil.core.TrefoilVpnService
import com.lupangoding.trefoil.core.TrefoilWidgetProvider
import com.lupangoding.trefoil.core.TunnelStage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libruntime.Libruntime
import io.nekohasekai.libxray.Libxray
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.StatusMessage
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The single seam between Dart and the native tunnel.
 *
 * Dart owns profiles, subscriptions and the sing-box JSON it wants to run; this side
 * owns the VPN permission, the service lifecycle and the live telemetry. Keeping that
 * split sharp is what stops VPN state from being duplicated in two places that can
 * disagree.
 */
class TrefoilBridge(private val activity: Activity, messenger: BinaryMessenger) {

    private val control = MethodChannel(messenger, "trefoil/control")
    private val statusChannel = EventChannel(messenger, "trefoil/status")
    private val logChannel = EventChannel(messenger, "trefoil/logs")
    private val groupChannel = EventChannel(messenger, "trefoil/groups")
    private val connectionChannel = EventChannel(messenger, "trefoil/connections")
    private val trafficChannel = EventChannel(messenger, "trefoil/traffic")

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var statusSink: EventChannel.EventSink? = null
    private var logSink: EventChannel.EventSink? = null
    private var groupSink: EventChannel.EventSink? = null
    private var connectionSink: EventChannel.EventSink? = null
    private var trafficSink: EventChannel.EventSink? = null

    /**
     * Shared by the connections screen and the split speed meter, and alive only
     * while at least one of them is listening and the tunnel is up.
     *
     * The core reports every connection open, close and byte count, which is far too
     * chatty to leave running behind a UI nobody is looking at -- but it is also the
     * only place a per-outbound breakdown exists, so the meter has to come from here.
     */
    private val connectionsClient = ConnectionsClient(activity) { snapshot ->
        main.post { connectionSink?.success(snapshot) }
    }

    /** Wall clock of the last throughput reading, for turning bytes into a rate. */
    private var lastTrafficAt = 0L

    private val trafficTicker = object : Runnable {
        override fun run() {
            emitTraffic()
            main.postDelayed(this, TRAFFIC_INTERVAL_MS)
        }
    }

    /** Replayed to a late subscriber, so opening the server list shows what is known. */
    @Volatile
    private var lastGroups: List<Map<String, Any?>> = emptyList()

    /** Current quick routing mode, empty until the core reports one. */
    @Volatile
    private var clashMode: String = ""
    private var pendingPrepare: MethodChannel.Result? = null

    /** A save waiting on the system file picker, with the text it will write. */
    private var pendingSave: Pair<MethodChannel.Result, String>? = null

    /** An open waiting on the system file picker. */
    private var pendingOpen: MethodChannel.Result? = null

    /** Latest telemetry, merged into every status event so the UI gets one object. */
    @Volatile
    private var lastStatus: StatusMessage? = null

    private val coreClient = CoreClient(
        context = activity,
        onStatus = { status ->
            lastStatus = status
            main.post { emitStatus() }
        },
        onLogs = { batch ->
            main.post {
                val sink = logSink ?: return@post
                if (batch.isEmpty()) {
                    sink.success(emptyList<Map<String, Any?>>())
                } else {
                    sink.success(batch.map { mapOf("level" to it.first, "message" to it.second) })
                }
            }
        },
        onGroups = { groups ->
            lastGroups = groups
            main.post { groupSink?.success(groups) }
        },
        onClashMode = { mode ->
            clashMode = mode
            main.post { emitStatus() }
        },
        onConnectedChange = { connected ->
            if (!connected) {
                lastStatus = null
                lastGroups = emptyList()
                clashMode = ""
            }
            main.post { emitStatus() }
        },
    )

    fun attach() {
        control.setMethodCallHandler { call, result -> onMethodCall(call.method, call.arguments, result) }

        statusChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statusSink = events
                emitStatus()
            }

            override fun onCancel(arguments: Any?) {
                statusSink = null
            }
        })

        logChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                logSink = events
            }

            override fun onCancel(arguments: Any?) {
                logSink = null
            }
        })

        connectionChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                connectionSink = events
                // Otherwise the screen renders a spinner forever: with the tunnel
                // down there is no subscription to make and nothing will ever arrive.
                if (ServiceState.current.stage != TunnelStage.STARTED) {
                    events?.error("not_connected", "The tunnel is not running", null)
                }
                syncConnectionsClient()
            }

            override fun onCancel(arguments: Any?) {
                connectionSink = null
                syncConnectionsClient()
            }
        })

        trafficChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                trafficSink = events
                lastTrafficAt = 0L
                syncConnectionsClient()
                main.postDelayed(trafficTicker, TRAFFIC_INTERVAL_MS)
            }

            override fun onCancel(arguments: Any?) {
                trafficSink = null
                main.removeCallbacks(trafficTicker)
                syncConnectionsClient()
            }
        })

        groupChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                groupSink = events
                if (lastGroups.isNotEmpty()) events?.success(lastGroups)
            }

            override fun onCancel(arguments: Any?) {
                groupSink = null
            }
        })

        // Mirror service state into the status stream. Telemetry alone is not enough:
        // it stops arriving the moment the tunnel drops, which is exactly when the UI
        // most needs to hear about it.
        scope.launch {
            ServiceState.state.collect { state ->
                if (state.stage == TunnelStage.STARTED) coreClient.start() else coreClient.stop()
                // The connections subscription cannot be made before the core is up,
                // and a screen that subscribed while disconnected would otherwise
                // never be given one.
                syncConnectionsClient()
                emitStatus()
            }
        }
    }

    /**
     * Starts or stops the shared connections subscription to match demand.
     *
     * Both start and stop are idempotent, so this can be called from any of the
     * things that change the answer.
     */
    private fun syncConnectionsClient() {
        val wanted = (connectionSink != null || trafficSink != null) &&
            ServiceState.current.stage == TunnelStage.STARTED
        if (wanted) connectionsClient.start() else connectionsClient.stop()
    }

    /**
     * Publishes throughput split by outbound.
     *
     * Driven by a timer rather than by incoming events: the core stops sending byte
     * updates entirely when nothing is moving, and a meter that simply stopped
     * updating would sit at the last rate it saw instead of falling to zero.
     */
    private fun emitTraffic() {
        val sink = trafficSink ?: return
        val now = SystemClock.elapsedRealtime()
        val elapsed = if (lastTrafficAt == 0L) TRAFFIC_INTERVAL_MS else now - lastTrafficAt
        lastTrafficAt = now
        val delta = connectionsClient.takeTraffic()
        // Measured against the elapsed time rather than the nominal interval, so a
        // tick the main thread delivered late does not read as a spike.
        fun rate(bytes: Long) = if (elapsed <= 0L) 0L else bytes * 1000L / elapsed
        sink.success(
            mapOf(
                "directUp" to rate(delta.directUp),
                "directDown" to rate(delta.directDown),
                "proxyUp" to rate(delta.proxyUp),
                "proxyDown" to rate(delta.proxyDown),
            ),
        )
    }

    fun detach() {
        control.setMethodCallHandler(null)
        statusChannel.setStreamHandler(null)
        logChannel.setStreamHandler(null)
        groupChannel.setStreamHandler(null)
        connectionChannel.setStreamHandler(null)
        trafficChannel.setStreamHandler(null)
        main.removeCallbacks(trafficTicker)
        connectionsClient.stop()
        coreClient.stop()
        scope.cancel()
        statusSink = null
        logSink = null
        groupSink = null
        connectionSink = null
        trafficSink = null
        pendingPrepare = null
        pendingSave = null
        pendingOpen = null
    }

    // ---- method calls ----------------------------------------------------

    private fun onMethodCall(method: String, args: Any?, result: MethodChannel.Result) {
        when (method) {
            "prepareVpn" -> prepareVpn(result)
            "start" -> start(args, result)
            "stop" -> stop(result)
            "currentStatus" -> result.success(statusPayload())
            "validateConfig" -> validateConfig(args, result)
            "formatConfig" -> formatConfig(args, result)
            "installedApps" -> installedApps(result)
            "appIcon" -> appIcon(args, result)
            "closeConnections" -> {
                connectionsClient.closeAll()
                result.success(null)
            }
            "closeConnection" -> {
                connectionsClient.close(args as? String ?: "")
                result.success(null)
            }
            "encryptBackup" -> backup(args, result, encrypt = true)
            "decryptBackup" -> backup(args, result, encrypt = false)
            "copySensitive" -> copySensitive(args as? String, result)
            "saveTextFile" -> saveTextFile(args, result)
            "openTextFile" -> openTextFile(result)
            "configVersion" -> result.success(AppPrefs.configVersion(activity))
            "setAppLocale" -> {
                AppPrefs.setLocaleTag(activity, args as? String)
                // Redrawn now rather than at the next state change, so a language
                // picked in the app reaches the home screen straight away.
                TrefoilWidgetProvider.refresh(activity)
                result.success(null)
            }
            "notificationSpeed" -> result.success(AppPrefs.notificationSpeed(activity))
            "setNotificationSpeed" -> {
                AppPrefs.setNotificationSpeed(activity, args as? String ?: AppPrefs.SPEED_TOTAL)
                result.success(null)
            }
            "notificationInterval" -> result.success(AppPrefs.notificationIntervalSeconds(activity))
            "setNotificationInterval" -> {
                AppPrefs.setNotificationIntervalSeconds(activity, (args as? Int) ?: 1)
                result.success(null)
            }
            "resetOnNetworkChange" -> result.success(AppPrefs.resetOnNetworkChange(activity))
            "setResetOnNetworkChange" -> {
                AppPrefs.setResetOnNetworkChange(activity, args as? Boolean ?: false)
                result.success(null)
            }
            "resetOnWake" -> result.success(AppPrefs.resetOnWake(activity))
            "setResetOnWake" -> {
                AppPrefs.setResetOnWake(activity, args as? Boolean ?: false)
                result.success(null)
            }
            "groupInNotification" -> result.success(AppPrefs.groupInNotification(activity))
            "setGroupInNotification" -> {
                AppPrefs.setGroupInNotification(activity, args as? Boolean ?: false)
                result.success(null)
            }
            "metered" -> result.success(AppPrefs.metered(activity))
            "setMetered" -> {
                AppPrefs.setMetered(activity, args as? Boolean ?: false)
                result.success(null)
            }
            "wakeLock" -> result.success(AppPrefs.wakeLock(activity))
            "setWakeLock" -> {
                AppPrefs.setWakeLock(activity, args as? Boolean ?: false)
                result.success(null)
            }
            "trafficStats" -> result.success(AppPrefs.trafficStats(activity))
            "setTrafficStats" -> {
                AppPrefs.setTrafficStats(activity, args as? Boolean ?: true)
                result.success(null)
            }
            "memoryLimit" -> result.success(AppPrefs.memoryLimit(activity))
            "setMemoryLimit" -> {
                val enabled = args as? Boolean ?: false
                AppPrefs.setMemoryLimit(activity, enabled)
                // Applied at once rather than at the next setup: someone reaching for
                // this is being killed for memory now.
                runCatching { Libruntime.setLowMemory(enabled) }
                result.success(null)
            }
            "debugMode" -> result.success(AppPrefs.debug(activity))
            "setDebugMode" -> {
                AppPrefs.setDebug(activity, args as? Boolean ?: false)
                result.success(null)
            }
            "batteryOptimized" -> result.success(isBatteryOptimized())
            "requestIgnoreBatteryOptimizations" -> {
                result.success(requestIgnoreBatteryOptimizations())
            }
            "alwaysOn" -> result.success(AlwaysOn.status(activity))
            "openVpnSettings" -> result.success(openVpnSettings())
            "autoStart" -> result.success(AutoStart.isEnabled(activity))
            "setAutoStart" -> {
                AutoStart.setEnabled(activity, args as? Boolean ?: false)
                result.success(null)
            }
            "setMode" -> {
                coreClient.setClashMode(args as? String ?: "Rule")
                result.success(null)
            }
            "forgetServerUsage" -> {
                (args as? String)?.takeIf { it.isNotEmpty() }?.let { ServerUsage.forget(activity, it) }
                result.success(null)
            }
            "urlTest" -> {
                coreClient.urlTest(args as? String ?: "proxy")
                result.success(null)
            }
            "selectOutbound" -> {
                @Suppress("UNCHECKED_CAST")
                val map = args as? Map<String, Any?>
                val group = map?.get("group") as? String
                val outbound = map?.get("outbound") as? String
                if (group == null || outbound == null) {
                    result.error("bad_args", "selectOutbound requires {group, outbound}", null)
                } else {
                    coreClient.selectOutbound(group, outbound)
                    result.success(null)
                }
            }
            "generateWireGuardKey" -> {
                try {
                    result.success(Libxray.generateWireGuardKeyPair())
                } catch (t: Throwable) {
                    result.error("keygen_failed", t.message ?: t.toString(), null)
                }
            }
            "coreVersion" -> result.success(
                mapOf(
                    "singBox" to runCatching { Libbox.version() }.getOrDefault("unknown"),
                    "xray" to runCatching { Libxray.version() }.getOrDefault("unknown"),
                ),
            )
            else -> result.notImplemented()
        }
    }

    /**
     * Whether Android is still allowed to doze this app.
     *
     * True is the state worth acting on: a dozed VPN drops its tunnel while the
     * screen is off, which reads to the user as the app being unreliable.
     */
    private fun isBatteryOptimized(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val power = activity.getSystemService(PowerManager::class.java) ?: return false
        return !power.isIgnoringBatteryOptimizations(activity.packageName)
    }

    /**
     * Opens the exemption prompt, falling back to the battery-optimisation list.
     *
     * The direct request is refused outright on some builds and by some vendors, so
     * the fallback is what keeps the setting reachable rather than a dead row.
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:${activity.packageName}"))
        if (runCatching { activity.startActivity(direct) }.isSuccess) return true
        val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        return runCatching { activity.startActivity(list) }.isSuccess
    }

    /**
     * Opens Android's VPN settings, where always-on and its lockdown live.
     *
     * There is no intent that lands on this app's own always-on switch, and no API
     * to set it: the system deliberately keeps a kill switch out of reach of the app
     * it governs. The list is as close as an app can get, so the row that opens it
     * says what to tap once there.
     */
    private fun openVpnSettings(): Boolean {
        val vpn = Intent(Settings.ACTION_VPN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (runCatching { activity.startActivity(vpn) }.isSuccess) return true
        // Absent on a few vendor builds; the top-level settings still get them there.
        val fallback = Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return runCatching { activity.startActivity(fallback) }.isSuccess
    }

    /**
     * Asks for VPN consent. Returns true once the tunnel may be started; the system
     * dialog is shown at most once per install unless the user revokes it.
     */
    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = try {
            VpnService.prepare(activity)
        } catch (t: Throwable) {
            // Devices with VPN disabled by policy throw rather than returning an intent.
            result.error("vpn_unavailable", t.message, null)
            return
        }
        requestNotificationPermission()
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingPrepare != null) {
            result.error("prepare_in_progress", "A consent dialog is already open", null)
            return
        }
        pendingPrepare = result
        activity.startActivityForResult(intent, REQUEST_VPN_CONSENT)
    }

    /**
     * Asks for POST_NOTIFICATIONS on Android 13+, best effort.
     *
     * The tunnel runs either way — a foreground service still starts without the
     * permission, the notification is simply invisible. But that notification carries
     * the Disconnect action and is the only sign the VPN is ours, so it is worth
     * asking for. Deliberately not awaited: a declined prompt must not block connecting.
     */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return
        runCatching {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val uri = data?.data.takeIf { resultCode == Activity.RESULT_OK }
        when (requestCode) {
            REQUEST_VPN_CONSENT -> {
                pendingPrepare?.success(resultCode == Activity.RESULT_OK)
                pendingPrepare = null
            }
            REQUEST_SAVE_FILE -> {
                val (result, text) = pendingSave ?: return true
                pendingSave = null
                // Backing out of the picker is a choice, not a failure.
                if (uri == null) return true.also { result.success(false) }
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) {
                            // "w" rather than "wt": the document is new, and some
                            // providers refuse the truncating mode outright.
                            activity.contentResolver.openOutputStream(uri, "w")
                                ?.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                                ?: error("The file could not be opened for writing")
                        }
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("save_failed", t.message ?: t.toString(), null)
                    }
                }
            }
            REQUEST_OPEN_FILE -> {
                val result = pendingOpen ?: return true
                pendingOpen = null
                if (uri == null) return true.also { result.success(null) }
                scope.launch {
                    try {
                        val text = withContext(Dispatchers.IO) { readBounded(uri) }
                        if (text == null) {
                            result.error("too_large", "That file is too large to be a backup", null)
                        } else {
                            result.success(text)
                        }
                    } catch (t: Throwable) {
                        result.error("open_failed", t.message ?: t.toString(), null)
                    }
                }
            }
            else -> return false
        }
        return true
    }

    /**
     * Hands the text to a file the user picks, through the system picker: no storage
     * permission, and it can be a cloud drive as easily as the phone.
     */
    private fun saveTextFile(args: Any?, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val map = args as? Map<String, Any?>
        val name = map?.get("name") as? String
        val text = map?.get("text") as? String
        if (name.isNullOrBlank() || text == null) {
            result.error("bad_args", "saveTextFile requires {name, text}", null)
            return
        }
        if (pendingSave != null || pendingOpen != null) {
            result.error("busy", "A file picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TITLE, name)
        pendingSave = result to text
        runCatching { activity.startActivityForResult(intent, REQUEST_SAVE_FILE) }.onFailure {
            pendingSave = null
            result.error("no_file_picker", it.message ?: "No app here can save files", null)
        }
    }

    /** The text of a file the user picks, or null when they back out. */
    private fun openTextFile(result: MethodChannel.Result) {
        if (pendingSave != null || pendingOpen != null) {
            result.error("busy", "A file picker is already open", null)
            return
        }
        // Any type: cloud drives and chat apps report a saved backup as everything
        // from text/plain to application/octet-stream.
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
        pendingOpen = result
        runCatching { activity.startActivityForResult(intent, REQUEST_OPEN_FILE) }.onFailure {
            pendingOpen = null
            result.error("no_file_picker", it.message ?: "No app here can open files", null)
        }
    }

    /**
     * Reads at most [MAX_OPEN_BYTES], so picking a video by mistake is an error
     * message rather than the app running out of memory. Null when over.
     */
    private fun readBounded(uri: Uri): String? {
        val input = activity.contentResolver.openInputStream(uri)
            ?: error("The file could not be opened")
        input.use { stream ->
            val out = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val read = stream.read(chunk)
                if (read < 0) break
                total += read
                if (total > MAX_OPEN_BYTES) return null
                out.write(chunk, 0, read)
            }
            return out.toString(Charsets.UTF_8.name())
        }
    }

    private fun start(args: Any?, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val map = args as? Map<String, Any?> ?: run {
            result.error("bad_args", "start requires {config, profileName}", null)
            return
        }
        val config = map["config"] as? String
        if (config.isNullOrBlank()) {
            result.error("bad_args", "config must be a non-empty string", null)
            return
        }
        val profileName = map["profileName"] as? String ?: ""
        // Present only for servers that need the second core.
        val xrayConfig = map["xrayConfig"] as? String
        val amneziaConfig = map["amneziaConfig"] as? String
        val amneziaSocks = AmneziaRuntime.Socks.of(
            (map["amneziaPort"] as? Number)?.toInt(),
            map["amneziaUsername"] as? String,
            map["amneziaPassword"] as? String,
        )
        // Refused rather than started without: a core serving loopback with no
        // credentials is the exposure the credentials exist to close.
        if (amneziaConfig != null && amneziaSocks == null) {
            result.error("bad_args", "an AmneziaWG config needs its SOCKS port and credentials", null)
            return
        }

        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    LibboxRuntime.ensureSetup(activity)
                    // Reject a broken config here rather than letting the service start,
                    // fail, and surface as a mystery "disconnected".
                    Libbox.checkConfig(config)
                    // Validate Xray's config too, for the same reason: a failure here
                    // is far clearer than a tunnel that comes up and never carries data.
                    if (xrayConfig != null) Libxray.test(xrayConfig)
                    LibboxRuntime.writeConfig(activity, config)
                    LibboxRuntime.writeXrayConfig(activity, xrayConfig)
                    // Not validated ahead of time the way Xray's is: the AmneziaWG
                    // library has no check that stops short of raising the device, and
                    // raising one here would bind the very socket the service is about
                    // to want. It fails loudly at start instead.
                    LibboxRuntime.writeAmneziaConfig(activity, amneziaConfig)
                    LibboxRuntime.writeAmneziaSocks(activity, amneziaSocks.takeIf { amneziaConfig != null })
                    // With the files it describes, so the two cannot disagree.
                    AppPrefs.rememberConfigVersion(activity, (map["configVersion"] as? Number)?.toInt() ?: 0)
                }
                // Remembered so the tile and the boot receiver, which have no Flutter
                // engine to ask, can label and restart the same profile.
                AutoStart.rememberProfile(activity, profileName)
                // Same reason: the notification names the two halves of the traffic
                // split, and the service cannot look up a translation for itself.
                AppPrefs.rememberLabels(
                    activity,
                    proxy = map["proxyLabel"] as? String ?: "Proxy",
                    direct = map["directLabel"] as? String ?: "Direct",
                )
                AppPrefs.rememberGroupName(activity, map["groupName"] as? String ?: "")
                val intent = Intent(activity, TrefoilVpnService::class.java)
                    .putExtra(TrefoilVpnService.EXTRA_PROFILE_NAME, profileName)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    activity.startForegroundService(intent)
                } else {
                    activity.startService(intent)
                }
                result.success(null)
            } catch (t: Throwable) {
                result.error("start_failed", t.message ?: t.toString(), null)
            }
        }
    }

    private fun stop(result: MethodChannel.Result) {
        val intent = Intent(activity, TrefoilVpnService::class.java).setAction(TrefoilVpnService.ACTION_STOP)
        // Plain startService: the service is already foreground, and a stop must not
        // fail on the background-start restrictions that startForegroundService applies.
        runCatching { activity.startService(intent) }
        result.success(null)
    }

    private fun validateConfig(args: Any?, result: MethodChannel.Result) {
        val config = args as? String ?: run {
            result.error("bad_args", "validateConfig requires a string", null)
            return
        }
        scope.launch {
            val error = withContext(Dispatchers.IO) {
                runCatching {
                    LibboxRuntime.ensureSetup(activity)
                    Libbox.checkConfig(config)
                }.exceptionOrNull()?.message
            }
            result.success(error)
        }
    }

    private fun formatConfig(args: Any?, result: MethodChannel.Result) {
        val config = args as? String ?: run {
            result.error("bad_args", "formatConfig requires a string", null)
            return
        }
        scope.launch {
            try {
                val formatted = withContext(Dispatchers.IO) {
                    LibboxRuntime.ensureSetup(activity)
                    Libbox.formatConfig(config).value
                }
                result.success(formatted)
            } catch (t: Throwable) {
                result.error("format_failed", t.message ?: t.toString(), null)
            }
        }
    }

    /**
     * Copies text the clipboard should treat as a secret: a server link, a backup, a
     * password.
     *
     * Flagged so Android leaves it out of the preview it shows after a copy, and so
     * keyboards and clipboard managers that honour the flag keep it out of their
     * history. The constant has a name from Android 13; the key itself was honoured by
     * those apps before that, which is why it is set by value below 13.
     */
    private fun copySensitive(text: String?, result: MethodChannel.Result) {
        if (text == null) {
            result.error("bad_args", "copySensitive requires a string", null)
            return
        }
        val clipboard = activity.getSystemService(ClipboardManager::class.java)
        if (clipboard == null) {
            result.error("unavailable", "No clipboard on this device", null)
            return
        }
        val clip = ClipData.newPlainText("Trefoil", text)
        clip.description.extras = PersistableBundle().apply {
            putBoolean(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    ClipDescription.EXTRA_IS_SENSITIVE
                } else {
                    "android.content.extra.IS_SENSITIVE"
                },
                true,
            )
        }
        runCatching { clipboard.setPrimaryClip(clip) }
            .onSuccess { result.success(null) }
            .onFailure { result.error("copy_failed", it.message ?: it.toString(), null) }
    }

    /**
     * Every installed app but this one.
     *
     * System apps with no launcher entry are marked `background` rather than left
     * out. They are mostly noise for per-app rules, so the list hides them by default
     * — but some carry real traffic, Google Play Services above all, and leaving them
     * out entirely meant they could never be routed or excluded at all.
     */
    private fun installedApps(result: MethodChannel.Result) {
        scope.launch {
            val apps = withContext(Dispatchers.IO) {
                val pm = activity.packageManager
                runCatching {
                    // Flags 0: meta-data is never read here, and asking for it makes
                    // the system parse a bundle per app for nothing.
                    pm.getInstalledApplications(0)
                        .filter { it.packageName != activity.packageName }
                        .map {
                            val system = it.flags and ApplicationInfo.FLAG_SYSTEM != 0
                            mapOf(
                                "packageName" to it.packageName,
                                "label" to pm.getApplicationLabel(it).toString(),
                                "system" to system,
                                // Only asked of system apps: it is a lookup per app, and
                                // for anything the user installed the answer is moot.
                                "background" to (system && pm.getLaunchIntentForPackage(it.packageName) == null),
                            )
                        }
                        .sortedBy { (it["label"] as String).lowercase() }
                }.getOrDefault(emptyList())
            }
            result.success(apps)
        }
    }

    /**
     * One app's icon as PNG bytes, or null when it has none we can render.
     *
     * One at a time rather than alongside the list: a phone carries a few hundred
     * launcher apps, and rasterising every icon before the list can appear costs
     * seconds and megabytes to show twelve rows. The caller asks for the ones it is
     * about to draw. Rendering runs on the CPU pool, which is bounded by core count,
     * so a fast scroll queues work instead of spawning a thread per row.
     */
    private fun appIcon(args: Any?, result: MethodChannel.Result) {
        val packageName = args as? String
        if (packageName.isNullOrEmpty()) {
            result.error("bad_args", "appIcon requires a package name", null)
            return
        }
        scope.launch {
            val png = withContext(Dispatchers.Default) {
                runCatching {
                    val pm = activity.packageManager
                    // Size follows the display, because the icon is drawn at a fixed dp
                    // and either blurs or wastes bytes if the pixels are picked blind.
                    val px = (ICON_DP * activity.resources.displayMetrics.density).toInt()
                    pm.getApplicationIcon(packageName).toPng(px.coerceIn(48, 192))
                }.getOrNull()
            }
            result.success(png)
        }
    }

    /**
     * Drawn into a square of our choosing rather than its own intrinsic size: an
     * adaptive icon has no single natural size, and some legacy ones report zero,
     * which would otherwise be a crash on an allocation of 0 x 0.
     */
    private fun Drawable.toPng(size: Int): ByteArray? {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        try {
            setBounds(0, 0, size, size)
            draw(Canvas(bitmap))
            val out = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) return null
            return out.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Key derivation is intentionally expensive, so it runs off the main thread —
     * roughly a second on a mid-range phone, which would otherwise drop frames.
     */
    private fun backup(args: Any?, result: MethodChannel.Result, encrypt: Boolean) {
        @Suppress("UNCHECKED_CAST")
        val map = args as? Map<String, Any?>
        val payload = map?.get("data") as? String
        val password = map?.get("password") as? String
        if (payload.isNullOrEmpty() || password.isNullOrEmpty()) {
            result.error("bad_args", "data and password are required", null)
            return
        }
        scope.launch {
            try {
                val output = withContext(Dispatchers.Default) {
                    if (encrypt) {
                        BackupCrypto.encrypt(payload, password)
                    } else {
                        BackupCrypto.decrypt(payload, password)
                    }
                }
                result.success(output)
            } catch (_: BackupCrypto.WrongPassword) {
                // Codes rather than sentences: the app says these in the user's language.
                result.error("wrong_password", "Wrong password, or the backup is damaged", null)
            } catch (_: BackupCrypto.NotABackup) {
                result.error("not_a_backup", "That does not look like a Trefoil backup", null)
            } catch (t: Throwable) {
                result.error("backup_failed", t.message ?: t.toString(), null)
            }
        }
    }

    // ---- status ----------------------------------------------------------

    private fun statusPayload(): Map<String, Any?> {
        val state = ServiceState.current.toMap()
        val status = lastStatus
        return state + mapOf(
            "uplink" to (status?.uplink ?: 0L),
            "downlink" to (status?.downlink ?: 0L),
            "uplinkTotal" to (status?.uplinkTotal ?: 0L),
            "downlinkTotal" to (status?.downlinkTotal ?: 0L),
            "memory" to (status?.memory ?: 0L),
            "goroutines" to (status?.goroutines ?: 0),
            "connectionsIn" to (status?.connectionsIn ?: 0),
            "connectionsOut" to (status?.connectionsOut ?: 0),
            "trafficAvailable" to (status?.trafficAvailable ?: false),
            "mode" to clashMode,
        )
    }

    private fun emitStatus() {
        statusSink?.success(statusPayload())
    }

    private companion object {
        const val REQUEST_VPN_CONSENT = 0x7401
        const val REQUEST_NOTIFICATIONS = 0x7402
        const val REQUEST_SAVE_FILE = 0x7403
        const val REQUEST_OPEN_FILE = 0x7404

        /** Far beyond any backup; small enough that a wrong pick cannot hurt. */
        const val MAX_OPEN_BYTES = 16L * 1024 * 1024

        /** Matches the core's own status interval, so one reading covers one batch. */
        const val TRAFFIC_INTERVAL_MS = 1_000L

        /** The size the per-app list draws an icon at; the bitmap is made to match. */
        const val ICON_DP = 40
    }
}
