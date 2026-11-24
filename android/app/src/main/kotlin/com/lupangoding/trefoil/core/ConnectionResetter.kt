package com.lupangoding.trefoil.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Closes the core's open connections on the events that leave them stranded.
 *
 * A connection established over WIFI does not survive the switch to mobile data; it
 * simply stops carrying data and sits there until something times out, which to the
 * user is the tunnel having quietly broken. Closing them makes the apps that own
 * them reconnect at once, over the link that actually works now.
 *
 * The same is true of a device coming out of a deep sleep, where sockets have been
 * idle long enough for the far end to have given up on them.
 *
 * Deliberately not subscribed to anything: closing connections is an ordinary RPC on
 * the command server, so this opens a client, asks, and closes it again rather than
 * holding the core's chattiest stream open for the sake of one call.
 */
class ConnectionResetter(private val context: Context) : CommandClientHandler {

    private var receiver: BroadcastReceiver? = null

    fun start() {
        if (receiver != null) return
        // Screen-on is the closest thing to "the device woke up" that an app can
        // observe without holding a wake lock of its own.
        val filter = IntentFilter(Intent.ACTION_SCREEN_ON)
        val target = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (AppPrefs.resetOnWake(this@ConnectionResetter.context)) reset()
            }
        }
        runCatching { context.registerReceiver(target, filter) }
            .onSuccess { receiver = target }
    }

    fun stop() {
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
        // Whatever is still waiting on a core that is going away.
        val waiting = open.getAndSet(null) ?: return
        scope.launch { runCatching { waiting.disconnect() } }
    }

    /** Called by the network monitor when the underlying link changes. */
    fun onNetworkChanged() {
        if (AppPrefs.resetOnNetworkChange(context)) reset()
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The client of the reset under way, if there is one. */
    private val open = AtomicReference<CommandClient?>(null)

    /**
     * Off whichever thread noticed: one is the main thread and the other the system's
     * connectivity callbacks, and connecting to the core waits for it.
     *
     * One at a time. A handover changes the link several times in a second, and the
     * first reset already closes everything the others would.
     */
    private fun reset() {
        val client = CommandClient(this, CommandClientOptions())
        if (!open.compareAndSet(null, client)) return
        // Best effort throughout: a failure here costs the user a slower recovery,
        // never a broken tunnel, so nothing is worth propagating.
        scope.launch {
            runCatching {
                client.connect()
                client.closeConnections()
            }
            runCatching { client.disconnect() }
            open.compareAndSet(client, null)
        }
    }

    // Nothing is subscribed to; the interface still has to be satisfied.
    override fun connected() = Unit
    override fun disconnected(message: String?) = Unit
    override fun clearLogs() = Unit
    override fun writeLogs(messages: LogIterator?) = Unit
    override fun writeStatus(message: StatusMessage?) = Unit
    override fun writeGroups(groups: OutboundGroupIterator?) = Unit
    override fun writeConnectionEvents(events: ConnectionEvents?) = Unit
    override fun initializeClashMode(modes: StringIterator?, currentMode: String?) = Unit
    /** Groups arrive through writeGroups; this per-item stream is not used. */
    override fun writeOutbounds(message: OutboundGroupItemIterator?) = Unit

    override fun updateClashMode(newMode: String?) = Unit
    override fun setDefaultLogLevel(level: Int) = Unit
}
