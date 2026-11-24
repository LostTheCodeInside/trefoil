package com.lupangoding.trefoil.bridge

import android.content.Context
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Reads live status and logs out of the running core.
 *
 * The core does not push into the UI directly. It hosts a command server on
 * loopback, and this client subscribes to it — the same path sing-box's own clients
 * use. Going through the documented channel rather than touching the service object
 * means the core can later move to its own process without the UI noticing.
 *
 * Callbacks arrive on a Go thread; [onStatus] and [onLogs] are responsible for
 * getting themselves onto the main thread before touching Flutter.
 */
class CoreClient(
    private val context: Context,
    private val onStatus: (StatusMessage) -> Unit,
    private val onLogs: (List<Pair<Int, String>>) -> Unit,
    private val onGroups: (List<Map<String, Any?>>) -> Unit,
    private val onClashMode: (String) -> Unit,
    private val onConnectedChange: (Boolean) -> Unit,
) : CommandClientHandler {

    private var client: CommandClient? = null
    private val running = AtomicBoolean(false)

    /** [intervalSeconds] is how often the core reports; see AppPrefs. */
    fun start(intervalSeconds: Int = 1) {
        if (!running.compareAndSet(false, true)) return
        val options = CommandClientOptions().apply {
            // Nanoseconds — this is a Go time.Duration.
            statusInterval = intervalSeconds.coerceAtLeast(1) * 1_000_000_000L
            addCommand(Libbox.CommandStatus)
            addCommand(Libbox.CommandLog)
            // Outbound groups carry the latency measurements and the current
            // selection, which is what lets the UI show and change them live.
            addCommand(Libbox.CommandGroup)
            // Carries the quick mode (Rule/Global/Direct) and its changes.
            addCommand(Libbox.CommandClashMode)
        }
        val c = CommandClient(this, options)
        client = c
        // connect() fails whenever the tunnel is down, which is an ordinary state
        // rather than an error: the UI simply shows nothing until the core is up.
        runCatching { c.connect() }.onFailure { running.set(false) }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        runCatching { client?.disconnect() }
        client = null
    }

    // ---- CommandClientHandler --------------------------------------------

    override fun connected() = onConnectedChange(true)

    override fun disconnected(message: String?) = onConnectedChange(false)

    override fun writeStatus(message: StatusMessage) = onStatus(message)

    override fun writeLogs(messages: LogIterator) {
        val batch = mutableListOf<Pair<Int, String>>()
        while (messages.hasNext()) {
            val entry = messages.next()
            batch.add(entry.level to entry.message)
        }
        if (batch.isNotEmpty()) onLogs(batch)
    }

    override fun clearLogs() = onLogs(emptyList())

    override fun writeGroups(groups: OutboundGroupIterator?) {
        val out = mutableListOf<Map<String, Any?>>()
        while (groups != null && groups.hasNext()) {
            val group = groups.next()
            val items = mutableListOf<Map<String, Any?>>()
            val iterator = group.items
            while (iterator.hasNext()) {
                val item = iterator.next()
                items.add(
                    mapOf(
                        "tag" to item.tag,
                        "type" to item.type,
                        // 0 means "never measured"; anything else is milliseconds.
                        "delay" to item.getURLTestDelay(),
                        "testedAt" to item.getURLTestTime(),
                    ),
                )
            }
            out.add(
                mapOf(
                    "tag" to group.tag,
                    "type" to group.type,
                    "selected" to group.selected,
                    "selectable" to group.selectable,
                    "items" to items,
                ),
            )
        }
        onGroups(out)
    }

    /** Measures every member of a group. Results arrive through [writeGroups]. */
    fun urlTest(groupTag: String) {
        runCatching { client?.urlTest(groupTag) }
    }

    /** Switches the active server without restarting the tunnel. */
    fun selectOutbound(groupTag: String, outboundTag: String) {
        runCatching { client?.selectOutbound(groupTag, outboundTag) }
    }

    /**
     * Switches the quick routing mode.
     *
     * No reconnect: the rules for every mode are already in the running config, and
     * only which of them matches changes.
     */
    fun setClashMode(mode: String) {
        runCatching { client?.setClashMode(mode) }
    }

    // Not subscribed to; required by the interface.
    override fun initializeClashMode(modes: StringIterator?, currentMode: String?) {
        onClashMode(currentMode.orEmpty())
    }

    /** Groups arrive through writeGroups; this per-item stream is not used. */
    override fun writeOutbounds(message: OutboundGroupItemIterator?) = Unit

    override fun updateClashMode(newMode: String?) {
        onClashMode(newMode.orEmpty())
    }
    override fun setDefaultLogLevel(level: Int) = Unit
    override fun writeConnectionEvents(events: ConnectionEvents?) = Unit
}
