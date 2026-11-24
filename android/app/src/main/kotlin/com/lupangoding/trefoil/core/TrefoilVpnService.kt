package com.lupangoding.trefoil.core

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.annotation.StringRes
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.lupangoding.trefoil.R
import com.lupangoding.trefoil.bridge.ConnectionsClient
import com.lupangoding.trefoil.bridge.CoreClient
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.Notification as BoxNotification
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SystemProxyStatus
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Owns the sing-box core and the Android TUN device for as long as the tunnel is up.
 *
 * Lifecycle, in order:
 *   1. `Libbox.setup` — process-global, must run exactly once before anything else.
 *   2. `CommandServer` — hosts the core and exposes status/log streams on a socket
 *      only this app can open. The UI reads those through a `CommandClient` rather than by reaching
 *      into this object, which is what keeps the door open to moving the core into
 *      its own process later without changing the UI.
 *   3. `startOrReloadService(config)` — actually brings the tunnel up.
 *
 * Start/stop are serialised onto a single-threaded scope: Android can deliver
 * onStartCommand and onDestroy in quick succession, and libbox is not re-entrant.
 */
class TrefoilVpnService : VpnService(), CommandServerHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))
    private val platform by lazy { PlatformInterfaceImpl(this) }
    private var commandServer: CommandServer? = null

    /**
     * The service's own status subscription, purely to keep the notification's
     * throughput readout live.
     *
     * It cannot borrow the UI's client: the tunnel is expected to run with the app
     * closed, which is exactly when the notification is the only thing the user can
     * see.
     */
    @Volatile
    private var statusClient: CoreClient? = null

    /**
     * Only alive when the notification is set to show proxy and direct separately.
     *
     * That breakdown exists nowhere but the core's per-connection feed, which is the
     * chattiest thing it publishes — so it runs for the notification only when the
     * user has asked for the split, and never merely because the tunnel is up.
     */
    @Volatile
    private var trafficClient: ConnectionsClient? = null
    private var lastTrafficAt = 0L

    /** The reporting interval [statusClient] was started with, so a change can restart it. */
    @Volatile
    private var statusInterval = 0

    /**
     * Held only when the user asks for it.
     *
     * Some vendors suspend the CPU hard enough that the tunnel stalls with the screen
     * off, and this is the only lever the app has against that. It costs battery by
     * design, which is why it is not the default.
     */
    private var wakeLock: android.os.PowerManager.WakeLock? = null

    /** Closes stranded connections when the link changes or the device wakes. */
    private val resetter by lazy { ConnectionResetter(this) }
    private val stopping = AtomicBoolean(false)

    /**
     * Which tunnel is the current one.
     *
     * Every start, replacement, restart and stop takes the next number. Bringing a
     * tunnel up takes seconds and a supervised restart waits for longer than that, so
     * whatever is part-way through checks that it still holds the latest before it goes
     * on, and before it reports anything.
     */
    private val generation = AtomicInteger()

    private fun isCurrent(mine: Int) = mine == generation.get() && !stopping.get()

    /**
     * The most recent start command Android has delivered.
     *
     * Kept so a stop can end the service by id rather than unconditionally: a start
     * that arrives while the previous tunnel is still tearing down must survive the
     * teardown finishing behind it.
     */
    private var lastStartId = 0

    /**
     * Brings the core back when it stops reporting.
     *
     * A tunnel that is up and dead looks exactly like one that is up and idle: the
     * interface exists, the notification says connected, and nothing goes anywhere.
     * Nothing was watching for that -- the boot receiver covers a reboot, and [Revival]
     * the process being killed, but neither notices a core that wedged while the service
     * around it stayed perfectly healthy.
     */
    private val supervisor = Supervisor()
    private var watchdog: Job? = null
    private var revival: Job? = null

    /**
     * When the core last reported, on the clock that stops while the device sleeps.
     * Zero while no report is expected.
     *
     * Not the wall clock: that moves when the network corrects it or the user does, and
     * a tunnel in perfect health was restarted for having been silent since a minute
     * that never happened. Nor the one that counts sleep, when nothing reports.
     */
    @Volatile
    private var lastStatusAt = 0L

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        screenOn = getSystemService(PowerManager::class.java)?.isInteractive ?: true
        runCatching {
            registerReceiver(
                screenReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_ON)
                    addAction(Intent.ACTION_SCREEN_OFF)
                },
            )
        }
        // The widget has no process of its own, so it cannot watch ServiceState.
        // Mirroring every transition to it here is what keeps it truthful when the
        // tunnel is started or stopped from the app, the tile or the notification.
        scope.launch {
            ServiceState.state.collect { TrefoilWidgetProvider.refresh(this@TrefoilVpnService) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel(null)
                return START_NOT_STICKY
            }
        }
        // A second start while one is already up or on its way. Always-on VPN and
        // auto-connect both fire after a reboot or an update, a fraction of a second
        // apart; starting again on top of the first took the working tunnel down with
        // it. Unless the caller means to put another in its place, it only wants the
        // tunnel up, and it is. Still promoted to the foreground, with what the
        // notification already says: every startForegroundService owes one.
        val stage = ServiceState.current.stage
        if (!stopping.get() && (stage == TunnelStage.STARTED || stage == TunnelStage.STARTING)) {
            startForegroundNotification(shownContent ?: connectingContent(""))
            if (intent?.getBooleanExtra(EXTRA_REPLACE, false) == true) {
                replaceTunnel(intent.getStringExtra(EXTRA_PROFILE_NAME).orEmpty())
            }
            return START_STICKY
        }
        // Promote to foreground immediately. Android kills a service that calls
        // startForegroundService but does not post its notification within ~5s.
        startForegroundNotification(connectingContent(""))?.let { refused ->
            // Android does not always let an app do this from the background, and says
            // so by throwing: uncaught, a tunnel that could not come back by itself
            // became a crash as well.
            ServiceState.fail(startFailed(refused))
            stopSelf(startId)
            return START_NOT_STICKY
        }
        noteAlwaysOn()
        // Always-on starts this service from the system, with no extras and often no
        // intent at all. Falling back to the remembered profile is what stops that
        // path connecting under a blank name -- the tunnel came up either way, but
        // the notification and the UI both showed no server.
        // No intent means Android recreated us after a kill. Only then is the
        // persisted intent consulted: a kill that landed while the user was
        // disconnecting must not bring the tunnel back.
        if (intent == null && !AutoStart.isDesired(this)) {
            stopTunnel(null)
            return START_NOT_STICKY
        }
        val requested = intent?.getStringExtra(EXTRA_PROFILE_NAME).orEmpty()
        startTunnel(requested.ifEmpty { AutoStart.profileName(this) })
        // Sticky, so a tunnel Android kills under memory pressure may come back at once;
        // [Revival] is for when it does not. It is safe to be sticky precisely because
        // every path that ends the tunnel deliberately -- the user, a failed start, a
        // revoked consent -- calls stopSelf(), and Android does not recreate a service
        // that stopped itself. Only a kill brings us back here, and only with the config
        // that was running.
        //
        // Not START_REDELIVER_INTENT: the recreate arrives with no intent and falls
        // back to the remembered profile above, which is the same thing without
        // holding a copy of the original intent for hours.
        return START_STICKY
    }

    /**
     * Records whether Android is running this as an always-on VPN.
     *
     * Only a running VpnService can answer, and only from API 29 -- there is no way
     * to ask on behalf of an app that is not currently the tunnel. So it is captured
     * here, at the one moment it is knowable, for the settings screen to read.
     */
    private fun noteAlwaysOn() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        runCatching { AlwaysOn.record(this, active = isAlwaysOn, lockdown = isLockdownEnabled) }
    }

    private fun startTunnel(profileName: String) {
        stopping.set(false)
        val mine = announce(profileName)
        scope.launch { bringUp(profileName, mine) }
    }

    /**
     * Puts another tunnel in place of this one.
     *
     * A reconnect, in one step and with the TUN device left open across it. Stopping and
     * then starting gave the device up in between, and until the new tunnel had one of
     * its own every app on the phone was on the bare network.
     *
     * When the device would be opened differently it is a new one, and Android leaves a
     * moment between the two that cannot be mended here: shortest for most settings, and
     * about a second for strict route or the per-app list, which it treats as another VPN.
     * Only its own "block connections without VPN" covers that.
     */
    private fun replaceTunnel(profileName: String) {
        val mine = announce(profileName)
        updateNotification(connectingContent(profileName))
        scope.launch {
            teardown(holdTun = true)
            bringUp(profileName, mine)
        }
    }

    /** Takes the next generation and says that a tunnel is on its way. */
    private fun announce(profileName: String): Int {
        val mine = generation.incrementAndGet()
        // A new tunnel starts on the server it was asked for; the core says otherwise
        // only once it has switched.
        activeServer = null
        AutoStart.setDesired(this, true)
        ServiceState.update(stage = TunnelStage.STARTING, profileName = profileName, clearError = true)
        return mine
    }

    /**
     * Starts the cores on the config that has been saved. Only ever from [scope], with
     * nothing running: whatever was has been through [teardown] first.
     *
     * Overtaken part-way, it stops where it is. Whoever overtook it has queued a
     * teardown behind it on this same thread.
     */
    private fun bringUp(profileName: String, mine: Int) {
        if (!isCurrent(mine)) return
        try {
            val config = configFile().takeIf { it.isFile }?.readText()
                ?: error("No configuration has been saved yet")

            // The other cores first, when the selected server needs one: sing-box's
            // proxy outbound points at their loopback SOCKS inbound, so starting
            // the other way round leaves a window where the proxy refuses
            // connections.
            LibboxRuntime.xrayConfigFile(this)
                .takeIf { it.isFile }
                ?.readText()
                ?.let { XrayRuntime.start(this, it) }
            LibboxRuntime.amneziaConfigFile(this)
                .takeIf { it.isFile }
                ?.readText()
                ?.let { AmneziaRuntime.start(this, it, LibboxRuntime.readAmneziaSocks(this)) }
            if (!isCurrent(mine)) return

            LibboxRuntime.ensureSetup(this)

            val server = CommandServer(this, platform)
            commandServer = server
            server.start()
            server.startOrReloadService(config, overrideOptions())
            // Usually let go already, as the new device replaced it. A config without one
            // leaves the old in place, with nothing reading from it.
            platform.releaseHeldTun()
            if (!isCurrent(mine)) return

            ServiceState.update(stage = TunnelStage.STARTED, profileName = profileName)
            acquireWakeLockIfWanted()
            resetter.start()
            updateNotification(
                NotificationContent(
                    profileName.ifEmpty { text(R.string.status_connected) },
                    text(R.string.status_connected),
                    null,
                    null,
                ),
            )
            startStatusUpdates(profileName, mine)
            startWatchdog(profileName, mine)
            startRevival()
        } catch (t: Throwable) {
            // A failure here means the tunnel never came up: report it and tear
            // down rather than sitting in a permanent "starting" state.
            if (isCurrent(mine)) stopTunnel(startFailed(t))
        }
    }

    /** Keeps the alarm that would bring this tunnel back from going off. */
    private fun startRevival() {
        revival?.cancel()
        val since = SystemClock.uptimeMillis()
        revival = scope.launch {
            var settled = false
            while (isActive) {
                Revival.postpone(this@TrefoilVpnService)
                if (!settled && SystemClock.uptimeMillis() - since >= Revival.SETTLED_MS) {
                    settled = true
                    Revival.settled(this@TrefoilVpnService)
                }
                delay(Revival.EVERY_MS)
            }
        }
    }

    /** Why a tunnel did not come up, in the user's language and then in the core's words. */
    private fun startFailed(cause: Throwable): String =
        AppLocale.string(this, R.string.error_start_failed, cause.message ?: cause.toString())

    private fun stopTunnel(error: String?) {
        if (!stopping.compareAndSet(false, true)) return
        generation.incrementAndGet()
        // A held update would otherwise be posted when the screen comes back on,
        // resurrecting a "connected" notification for a tunnel that is gone.
        synchronized(notificationLock) { heldContent = null }
        // First, and outside the coroutine: a kill arriving between here and the
        // teardown finishing must already read as "not wanted".
        AutoStart.setDesired(this, false)
        ServiceState.update(stage = TunnelStage.STOPPING)
        val stopId = lastStartId
        scope.launch {
            teardown()
            Revival.cancel(this@TrefoilVpnService)
            // A start that arrived while this was tearing down has already cleared the
            // flag and queued itself behind us on this same single-threaded scope.
            // Finishing the stop from here would report STOPPED over its STARTING,
            // drop the foreground notification it has five seconds to post, and then
            // stop the service out from under it. That is a reconnect that leaves
            // everything off -- intermittently, depending on how long a teardown took.
            if (!stopping.get()) return@launch
            if (error != null) ServiceState.fail(error) else ServiceState.update(TunnelStage.STOPPED)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) stopForeground(true)
            // By id, so Android declines if anything has been started since -- belt
            // and braces with the check above, for the window between it and here.
            // Also what makes START_STICKY safe: a service that stops itself is not
            // recreated, so every deliberate end stays ended.
            stopSelf(stopId)
        }
    }

    /**
     * Everything that has to come down, without deciding what happens next.
     *
     * Shared by every way a tunnel ends, so that none can drift into tearing down less
     * than the others do -- which is how a second core ends up starting on top of one
     * that is still there.
     *
     * [holdTun] is for when another tunnel follows at once; see [replaceTunnel].
     */
    private fun teardown(holdTun: Boolean = false) {
        watchdog?.cancel()
        watchdog = null
        revival?.cancel()
        revival = null
        lastStatusAt = 0L
        statusClient?.stop()
        statusClient = null
        trafficClient?.stop()
        trafficClient = null
        releaseWakeLock()
        resetter.stop()
        // Persist before the counters go away with the session.
        UsageHistory.reset(this)
        ServerUsage.reset(this)
        runCatching { commandServer?.closeService() }
        runCatching { commandServer?.close() }
        commandServer = null
        // After sing-box: it is the only thing dialing them, so tearing them down
        // first would surface as connection errors during a normal disconnect.
        XrayRuntime.stop()
        AmneziaRuntime.stop()
        if (holdTun) platform.holdTun() else platform.closeTun()
    }

    /**
     * Brings the tunnel back after the core stopped reporting.
     *
     * Everything here is a guard. The delay is the supervisor's, growing with each
     * consecutive attempt; whether this is still the current tunnel is asked again after
     * it, because a user who disconnects or reconnects during the wait must win; and a
     * supervisor that has run out of attempts ends the tunnel with a message rather than
     * cycling it forever.
     *
     * The TUN device stays open throughout. The tunnel is wanted and is coming back, and
     * traffic that cannot go through it should wait rather than go around. The one that
     * follows is new all the same: the device may be what went wrong.
     */
    private fun restartTunnel(profileName: String) {
        if (stopping.get()) return
        val delayMs = supervisor.nextDelayMs(SystemClock.uptimeMillis())
        if (delayMs == null) {
            stopTunnel(text(R.string.error_core_gave_up))
            return
        }
        val mine = generation.incrementAndGet()
        ServiceState.update(stage = TunnelStage.STARTING, profileName = profileName)
        updateNotification(connectingContent(profileName))
        scope.launch {
            teardown(holdTun = true)
            platform.renewTun()
            delay(delayMs)
            bringUp(profileName, mine)
        }
    }

    /**
     * Watches for the core going quiet.
     *
     * Staleness rather than liveness: there is no call that asks the core whether it
     * is well, and one that returned "yes" from a wedged core would be worse than
     * nothing. What can be observed is that reports stopped arriving, which is true
     * of every way it can fail.
     */
    private fun startWatchdog(profileName: String, mine: Int) {
        watchdog?.cancel()
        lastStatusAt = SystemClock.uptimeMillis()
        watchdog = scope.launch {
            while (isActive) {
                delay(WATCHDOG_TICK_MS)
                if (!isCurrent(mine)) return@launch
                val now = SystemClock.uptimeMillis()
                if (supervisor.isStale(now, lastStatusAt, statusInterval)) {
                    // Under the name it goes by now, which a live switch changes.
                    restartTunnel(activeServer ?: profileName)
                    return@launch
                }
                supervisor.onHealthy(now)
            }
        }
    }

    /** The underlying link changed; see ConnectionResetter for what that costs. */
    fun onDefaultInterfaceChanged() {
        resetter.onNetworkChanged()
    }

    /** The user revoked VPN consent, or another VPN app took over. */
    override fun onRevoke() {
        stopTunnel(text(R.string.error_vpn_revoked))
    }

    override fun onDestroy() {
        // Guard against Android destroying us without an explicit stop.
        if (!stopping.getAndSet(true)) {
            generation.incrementAndGet()
            // On the scope, behind whatever it is in the middle of: torn down from here
            // at the same moment, a start under way went on building on what had just
            // been closed. With a limit, because this is the main thread and a core that
            // has wedged would otherwise take the app with it.
            runBlocking {
                withTimeoutOrNull(DESTROY_PATIENCE_MS) { scope.launch { teardown() }.join() }
            }
            platform.closeTun()
            ServiceState.update(TunnelStage.STOPPED)
        }
        runCatching { unregisterReceiver(screenReceiver) }
        scope.cancel()
        super.onDestroy()
    }

    // ---- CommandServerHandler (calls arriving from the core) ---------------

    override fun serviceStop() {
        stopTunnel(null)
    }

    override fun serviceReload() {
        val config = configFile().takeIf { it.isFile }?.readText() ?: return
        runCatching { commandServer?.startOrReloadService(config, overrideOptions()) }
            .onFailure { stopTunnel(startFailed(it)) }
    }

    /** Android has no system-wide proxy an app may set; sing-box handles this via TUN. */
    override fun getSystemProxyStatus(): SystemProxyStatus =
        SystemProxyStatus().apply { available = false; enabled = false }

    override fun setSystemProxyEnabled(isEnabled: Boolean) = Unit

    override fun writeDebugMessage(message: String) = Unit

    /** For exercising a crash reporter, which this app does not ship. */
    override fun triggerNativeCrash(): Unit = throw UnsupportedOperationException("not supported")

    /** There is no SSH agent on Android to connect to. */
    override fun connectSSHAgent(): Int = throw UnsupportedOperationException("no SSH agent")

    fun cancelCoreNotification(identifier: String) {
        runCatching { NotificationManagerCompat.from(this).cancel(identifier.hashCode()) }
    }

    fun postCoreNotification(notification: BoxNotification) {
        val builder = NotificationCompat.Builder(this, CHANNEL_CORE)
            .setSmallIcon(com.lupangoding.trefoil.R.drawable.ic_tunnel)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setAutoCancel(true)
        NotificationManagerCompat.from(this).also { manager ->
            // POST_NOTIFICATIONS may be denied on API 33+; dropping the notification
            // must never take the tunnel down with it.
            runCatching { manager.notify(notification.identifier.hashCode(), builder.build()) }
        }
    }

    /**
     * Runtime overrides for the core. Every field must be non-null.
     *
     * libbox dereferences this without a nil check, and a Go panic is not catchable
     * from Kotlin — it aborts the whole process. Passing null here crashed the app on
     * connect. The per-app package lists stay empty on purpose: they are already
     * expressed in the TUN inbound of the generated config, and setting them in both
     * places would let the two disagree.
     */
    private fun overrideOptions(): OverrideOptions = OverrideOptions().apply {
        autoRedirect = false
        includePackage = emptyList<String>().toBoxStringIterator()
        excludePackage = emptyList<String>().toBoxStringIterator()
    }

    /**
     * Holds the CPU awake, for who asked for that; see [wakeLock].
     */
    private fun acquireWakeLockIfWanted() {
        if (!AppPrefs.wakeLock(this) || wakeLock != null) return
        runCatching {
            val power = getSystemService(android.os.PowerManager::class.java) ?: return
            wakeLock = power
                .newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "trefoil:tunnel")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }

    private fun releaseWakeLock() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
    }

    /**
     * Subscribes to core status and rewrites the notification as throughput changes.
     *
     * Rate is whatever the command server publishes (once a second). The notification
     * is marked only-alert-once, so replacing it this often is silent.
     */
    private fun startStatusUpdates(profileName: String, mine: Int) {
        statusClient?.stop()
        statusInterval = AppPrefs.notificationIntervalSeconds(this)
        statusClient = CoreClient(
            context = this,
            onStatus = report@{ status ->
                // One last report can arrive after the tunnel it is about has gone.
                if (!isCurrent(mine)) return@report
                // The watchdog's only evidence that the core is alive.
                lastStatusAt = SystemClock.uptimeMillis()
                UsageHistory.observe(this, status.uplinkTotal, status.downlinkTotal)
                ServerUsage.observe(this, status.uplinkTotal, status.downlinkTotal)
                // Read every tick rather than captured once: the user can change it
                // while the tunnel is running, and the notification is the only thing
                // they can see at that point.
                val mode = AppPrefs.notificationSpeed(this)
                if ((mode == AppPrefs.SPEED_SPLIT) != (trafficClient != null)) {
                    onScope(mine) { syncTrafficClient(mode) }
                }
                // The interval is baked into the subscription, so changing it means
                // resubscribing. Done here rather than deferred to the next connect,
                // because a setting that appears to do nothing reads as broken.
                if (AppPrefs.notificationIntervalSeconds(this) != statusInterval) {
                    onScope(mine) {
                        if (AppPrefs.notificationIntervalSeconds(this) != statusInterval) {
                            startStatusUpdates(profileName, mine)
                        }
                    }
                    return@report
                }
                updateNotification(
                    notificationContent(notificationTitle(activeServer ?: profileName), mode, status),
                )
            },
            onLogs = {},
            // Only to learn which server is carrying traffic: a live switch changes
            // that without restarting anything, so the profile name the tunnel began
            // with stops being the answer.
            onGroups = report@{ groups ->
                if (!isCurrent(mine)) return@report
                activeServerOf(groups)?.let { active ->
                    ServerUsage.setActive(this, active)
                    if (active != activeServer) {
                        activeServer = active
                        // The tile and the widget read the name from here.
                        ServiceState.update(profileName = active)
                    }
                }
            },
            onClashMode = {},
            onConnectedChange = {},
        ).also { it.start(statusInterval) }
    }

    /**
     * Runs [block] where the tunnel is started and stopped, if it is still the one that
     * was up when this was asked.
     *
     * For what a report from the core decides. Reports arrive on the core's own thread,
     * and a client started from there could outlive the teardown running beside it.
     */
    private fun onScope(mine: Int, block: () -> Unit) {
        scope.launch { if (isCurrent(mine)) block() }
    }

    /**
     * The server carrying traffic, as the core last reported it. Differs from the one
     * the tunnel started with after a live switch, which moves the selector without a
     * restart — so the notification, the tile and the widget name this one. They used
     * to keep the name from connect time and went on showing a server no longer in use.
     */
    @Volatile
    private var activeServer: String? = null

    /**
     * The server behind the selector. "Fastest" is a group of its own, so when that is
     * the choice, the answer is whichever server it picked: naming the group would tell
     * the user nothing, and the traffic totals would land on an entry that is not a
     * server.
     */
    private fun activeServerOf(groups: List<Map<String, Any?>>): String? {
        fun selectedIn(tag: String) =
            (groups.firstOrNull { it["tag"] == tag }?.get("selected") as? String)?.takeIf { it.isNotEmpty() }
        val choice = selectedIn(GROUP_PROXY) ?: return null
        return if (choice == GROUP_AUTO) selectedIn(GROUP_AUTO) ?: choice else choice
    }

    /** Starts or stops the per-connection feed to match what the notification shows. */
    private fun syncTrafficClient(mode: String) {
        if (mode == AppPrefs.SPEED_SPLIT) {
            if (trafficClient == null) {
                lastTrafficAt = 0L
                trafficClient = ConnectionsClient(this).also { it.start() }
            }
        } else {
            trafficClient?.stop()
            trafficClient = null
        }
    }

    /**
     * The profile, optionally prefixed with the subscription it came from.
     *
     * Useful when several subscriptions hand out servers with similar names and the
     * notification is the only place the running one is visible.
     */
    private fun notificationTitle(profileName: String): String {
        val name = profileName.ifEmpty { text(R.string.status_connected) }
        if (!AppPrefs.groupInNotification(this)) return name
        val group = AppPrefs.groupName(this)
        return if (group.isEmpty()) name else "$group · $name"
    }

    private fun formatted(bytes: Long): String =
        runCatching { Libbox.formatBytes(bytes) }.getOrDefault("0 B")

    /** Download first: it is the number people watch, and the app orders it that way. */
    private fun rates(down: Long, up: Long) = "↓ ${formatted(down)}/s   ↑ ${formatted(up)}/s"

    /**
     * What the notification says, in the three places it can say it.
     *
     * The split used to be three lines of body text, which meant that while the
     * notification was collapsed — the state it is in almost all the time — the only
     * visible line was "Proxy", and the totals were not visible at all. So the
     * headline rate takes the collapsed line, the breakdown goes to the expanded
     * view, and the session total moves to the header where it is always in view
     * without costing a line.
     */
    private data class NotificationContent(
        val title: String,
        /** The collapsed line. */
        val summary: String?,
        /** The expanded body, or null to leave the notification single-line. */
        val detail: String?,
        /** Beside the app name, in both states. */
        val subText: String?,
    )

    private fun notificationContent(
        title: String,
        mode: String,
        status: io.nekohasekai.libbox.StatusMessage,
    ): NotificationContent {
        if (mode == AppPrefs.SPEED_OFF || !status.trafficAvailable) {
            return NotificationContent(title, text(R.string.status_connected), null, null)
        }
        val session = formatted(status.uplinkTotal + status.downlinkTotal)
        val headline = rates(status.downlink, status.uplink)
        val client = trafficClient
        if (mode != AppPrefs.SPEED_SPLIT || client == null) {
            return NotificationContent(title, headline, null, session)
        }

        val now = android.os.SystemClock.elapsedRealtime()
        // Against the elapsed time rather than the nominal one second, so a tick the
        // core delivered late does not read as a burst.
        val elapsed = if (lastTrafficAt == 0L) 1_000L else now - lastTrafficAt
        lastTrafficAt = now
        val delta = client.takeTraffic()
        fun rate(bytes: Long) = if (elapsed <= 0L) 0L else bytes * 1000L / elapsed

        val proxy = AppPrefs.proxyLabel(this)
        val direct = AppPrefs.directLabel(this)
        // Download only, and one line: someone who chose the split wants to see it
        // without pulling the notification open, and both directions do not fit.
        val summary =
            "$proxy ↓ ${formatted(rate(delta.proxyDown))}/s   ·   " +
                "$direct ↓ ${formatted(rate(delta.directDown))}/s"
        val detail = buildString {
            append(headline)
            append('\n')
            append("$proxy   ")
            append(rates(rate(delta.proxyDown), rate(delta.proxyUp)))
            append('\n')
            append("$direct   ")
            append(rates(rate(delta.directDown), rate(delta.directUp)))
        }
        return NotificationContent(title, summary, detail, session)
    }

    // ---- infrastructure ---------------------------------------------------

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_STATUS, text(R.string.channel_tunnel_status), NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) },
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_CORE, text(R.string.channel_core_messages), NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    /**
     * Built once each. These used to be created inside [buildNotification], which
     * runs once a second for as long as the tunnel is up: every tick queried the
     * PackageManager for the launch intent and made two IPC round trips to the
     * system to mint PendingIntents that never differ.
     */
    private val openIntent: PendingIntent? by lazy {
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
    }

    private val stopIntent: PendingIntent by lazy {
        PendingIntent.getService(
            this,
            1,
            Intent(this, TrefoilVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** What the notification currently says, so an unchanged tick posts nothing. */
    private var shownContent: NotificationContent? = null

    private fun buildNotification(content: NotificationContent): android.app.Notification {
        val open = openIntent
        val stop = stopIntent
        return NotificationCompat.Builder(this, CHANNEL_STATUS)
            .setSmallIcon(com.lupangoding.trefoil.R.drawable.ic_tunnel)
            .setContentTitle(content.title.ifEmpty { text(R.string.status_connected) })
            .setContentText(content.summary)
            .setSubText(content.subText)
            // Only when there is genuinely more to show. Attaching the style with the
            // same text as the collapsed line gives the reader an expander that does
            // nothing when they pull it.
            .apply {
                if (content.detail != null) {
                    setStyle(NotificationCompat.BigTextStyle().bigText(content.detail))
                }
            }
            .setContentIntent(open)
            // Lock-screen notifications show their actions. Asking for the unlock first
            // means whoever is holding the phone cannot switch the tunnel off with one
            // tap; on Android 11 and below the flag is simply not there to set.
            .addAction(
                NotificationCompat.Action.Builder(0, text(R.string.action_disconnect), stop)
                    .setAuthenticationRequired(true)
                    .build(),
            )
            .setOngoing(true)
            // Silent: this is replaced roughly once a second while traffic flows.
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun connectingContent(profileName: String) = NotificationContent(
        profileName.ifEmpty { text(R.string.status_connecting) },
        if (profileName.isEmpty()) null else text(R.string.status_connecting),
        null,
        null,
    )

    /** Null, or why Android would not have it. */
    private fun startForegroundNotification(content: NotificationContent): Throwable? = runCatching {
        val notification = buildNotification(content)
        synchronized(notificationLock) { shownContent = content }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }.exceptionOrNull()?.also { Log.w(TAG, "Not promoted to the foreground", it) }

    /**
     * Re-posts the notification, but only when it would actually read differently.
     *
     * While the tunnel is idle the throughput line is the same string every second,
     * and posting it anyway costs a binder round trip and a notification rebuild for
     * a pixel-identical result.
     */
    private fun updateNotification(content: NotificationContent) {
        synchronized(notificationLock) {
            if (shownContent == content) {
                heldContent = null
                return
            }
            if (!screenOn) {
                heldContent = content
                return
            }
            shownContent = content
        }
        runCatching {
            NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, buildNotification(content))
        }
    }

    // ---- the notification while nobody is looking ---------------------------

    /**
     * Whether the screen is on. While it is off, a throughput update every second is
     * a binder call and a SystemUI redraw that nobody sees, for as long as traffic
     * flows — a stream playing with the screen off is hours of them. The newest
     * content is held instead and posted the moment the screen comes back, so what
     * the user sees on waking is current.
     *
     * Status keeps flowing regardless: the watchdog and the traffic totals depend on
     * it. Only the redraw is skipped.
     */
    private var screenOn = true
    private var heldContent: NotificationContent? = null
    private val notificationLock = Any()

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val held = synchronized(notificationLock) {
                screenOn = intent.action != Intent.ACTION_SCREEN_OFF
                if (screenOn) heldContent.also { heldContent = null } else null
            }
            if (held != null && !stopping.get()) updateNotification(held)
        }
    }

    private fun configFile() = LibboxRuntime.configFile(this)

    /**
     * The service's own words, in the language the app was last set to. Resolved per
     * use rather than held, so a language change reaches the very next notification.
     */
    private fun text(@StringRes id: Int): String = AppLocale.string(this, id)

    companion object {
        const val ACTION_STOP = "com.lupangoding.trefoil.STOP"
        const val EXTRA_PROFILE_NAME = "profile_name"

        /** Put this tunnel in place of the one that is up, rather than leave that be. */
        const val EXTRA_REPLACE = "replace"

        private const val TAG = "TrefoilVpnService"

        private const val NOTIFICATION_ID = 1

        /** The selector and the "fastest" group, as ConfigBuilder names them. */
        private const val GROUP_PROXY = "proxy"
        private const val GROUP_AUTO = "auto"
        private const val CHANNEL_STATUS = "tunnel_status"
        private const val CHANNEL_CORE = "core_messages"

        /** Short of the five seconds after which Android calls an app unresponsive. */
        private const val DESTROY_PATIENCE_MS = 3_000L

        /**
         * How often the watchdog looks. Well under the shortest staleness threshold,
         * so a dead core is noticed within a few seconds of becoming one, and rare
         * enough that the check itself costs nothing worth measuring.
         */
        private const val WATCHDOG_TICK_MS = 5_000L
    }
}
