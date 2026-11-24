package com.lupangoding.trefoil.bridge

import android.content.Context
import com.lupangoding.trefoil.core.CoreCalls
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.Connection
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator

/**
 * Bytes seen since the previous reading, split by how routing sent them out.
 *
 * "Direct" is traffic routing sent straight out; everything else went through the
 * tunnel. Held as a plain total rather than a rate, because only the reader knows how
 * much time its own last reading covered.
 */
data class TrafficDelta(
    val directUp: Long = 0,
    val directDown: Long = 0,
    val proxyUp: Long = 0,
    val proxyDown: Long = 0,
)

/**
 * Live view of the core's open connections.
 *
 * Deliberately a separate client from [CoreClient], started only while the
 * connections screen is visible: the core reports every connection open, close and
 * byte-count change, which is far too chatty to leave running behind a UI nobody is
 * looking at.
 *
 * The core sends deltas, not snapshots, so the current picture is accumulated here.
 */
class ConnectionsClient(
    private val context: Context,
    /**
     * Null for a consumer that only wants [takeTraffic] — the notification, which
     * needs the totals and never the list. Building a map per connection per update
     * is the expensive half of this, and it is skipped entirely when nobody reads it.
     */
    private val onSnapshot: ((List<Map<String, Any?>>) -> Unit)? = null,
) : CommandClientHandler {

    @Volatile
    private var client: CommandClient? = null
    private val lane = CoreCalls.Lane()

    /**
     * Insertion-ordered so the list does not reshuffle on every update.
     *
     * Touched from two threads -- the core's callback thread fills it, the lane
     * clears it on start and stop -- so every access holds [lock]. Without
     * that, stopping the screen while the core was mid-update threw
     * ConcurrentModificationException out of a Go callback.
     */
    private val connections = LinkedHashMap<String, MutableMap<String, Any?>>()
    private val lock = Any()

    /**
     * Accumulated since the last [takeTraffic], guarded by [lock].
     *
     * The core's aggregate status counters carry no breakdown by outbound at all, so
     * a split readout can only be built here, where each connection's routed outbound
     * is known.
     */
    private var pending = TrafficDelta()

    /** Both return at once; see [CoreClient.start]. */
    fun start() = lane.post { open() }

    fun stop() = lane.post { close() }

    private fun open() {
        if (client != null) return
        synchronized(lock) {
            connections.clear()
            pending = TrafficDelta()
        }
        val options = CommandClientOptions().apply {
            statusInterval = 1_000_000_000L
            addCommand(Libbox.CommandConnections)
        }
        val c = CommandClient(this, options)
        client = c
        runCatching { c.connect() }.onFailure { close() }
    }

    private fun close() {
        val c = client ?: return
        client = null
        runCatching { c.disconnect() }
        synchronized(lock) { connections.clear() }
    }

    private fun connectedClient(): CommandClient = client ?: error("The tunnel is not running")

    /** Closes every open connection; the core reopens whatever is still needed. */
    suspend fun closeAll() = CoreCalls.call { connectedClient().closeConnections() }

    suspend fun close(id: String) = CoreCalls.call { connectedClient().closeConnection(id) }

    /** The packages the core resolved for a connection, or nothing when it did not. */
    private fun packageNames(connection: Connection): List<String> =
        runCatching {
            val info = connection.processInfo ?: return@runCatching emptyList()
            val names = info.packageNames()
            buildList {
                while (names.hasNext()) add(names.next())
            }
        }.getOrDefault(emptyList())

    override fun writeConnectionEvents(events: ConnectionEvents?) {
        if (events == null) return
        val snapshot = synchronized(lock) {
            // A reset means the core is re-sending from scratch, so anything we hold
            // is stale rather than merely out of date.
            if (events.reset) connections.clear()

            val iterator = events.iterator()
            while (iterator.hasNext()) {
                val event = iterator.next()
                val id = event.id
                when (event.type.toLong()) {
                    Libbox.ConnectionEventClosed -> connections.remove(id)
                    else -> {
                        val existing = connections[id]
                        if (existing == null) {
                            val connection = event.connection ?: continue
                            connections[id] = mutableMapOf(
                                "id" to id,
                                "network" to connection.network,
                                "protocol" to connection.protocol,
                                "domain" to connection.domain,
                                "destination" to connection.destination,
                                "source" to connection.source,
                                "outbound" to connection.fromOutbound,
                                "user" to connection.user,
                                // Which app opened it, when the core knows. It only
                                // knows when something asked it to look — a
                                // package_name routing rule is what does that — so
                                // this is empty for most people and free for all of
                                // them. Read once, here, rather than on every update:
                                // each name crosses the binding one call at a time.
                                "packages" to packageNames(connection),
                                "createdAt" to connection.createdAt,
                                "uplink" to connection.uplinkTotal,
                                "downlink" to connection.getDownlink(),
                            )
                        } else {
                            // Updates carry deltas, not totals.
                            existing["uplink"] =
                                (existing["uplink"] as? Long ?: 0L) + event.uplinkDelta
                            existing["downlink"] =
                                (existing["downlink"] as? Long ?: 0L) + event.downlinkDelta
                            // Only an update's deltas count toward throughput. A new
                            // connection arrives carrying its whole lifetime total,
                            // and on the first snapshot after subscribing that is
                            // every existing connection at once -- counted as a rate
                            // it would read as an enormous burst that never happened.
                            accumulate(
                                outbound = existing["outbound"] as? String,
                                up = event.uplinkDelta,
                                down = event.downlinkDelta,
                            )
                        }
                    }
                }
            }
            // A close event we never receive would otherwise keep its entry forever,
            // and every entry is copied across the platform channel on every update.
            // Oldest first, since the newest connections are the interesting ones.
            while (connections.size > MAX_CONNECTIONS) {
                connections.remove(connections.keys.first())
            }
            if (onSnapshot == null) emptyList() else connections.values.map { it.toMap() }
        }
        onSnapshot?.invoke(snapshot)
    }

    /** Call with [lock] held. */
    private fun accumulate(outbound: String?, up: Long, down: Long) {
        if (up == 0L && down == 0L) return
        // Anything routing did not send straight out went through the tunnel --
        // including a chained WARP endpoint, and including the empty case, since this
        // app's default route is the proxy.
        pending = if (outbound == DIRECT_OUTBOUND) {
            pending.copy(directUp = pending.directUp + up, directDown = pending.directDown + down)
        } else {
            pending.copy(proxyUp = pending.proxyUp + up, proxyDown = pending.proxyDown + down)
        }
    }

    /** Returns what has accumulated and starts counting again. */
    fun takeTraffic(): TrafficDelta = synchronized(lock) {
        val taken = pending
        pending = TrafficDelta()
        taken
    }

    // Not subscribed to; required by the interface.
    override fun connected() = Unit
    override fun disconnected(message: String?) = Unit
    override fun clearLogs() = Unit
    override fun writeLogs(messages: LogIterator?) = Unit
    override fun writeStatus(message: StatusMessage?) = Unit
    override fun writeGroups(groups: OutboundGroupIterator?) = Unit
    override fun initializeClashMode(modes: StringIterator?, currentMode: String?) = Unit
    /** Groups arrive through writeGroups; this per-item stream is not used. */
    override fun writeOutbounds(message: OutboundGroupItemIterator?) = Unit

    override fun updateClashMode(newMode: String?) = Unit
    override fun setDefaultLogLevel(level: Int) = Unit

    private companion object {
        /** Far more than anyone reads, and low enough to stay a bounded cost. */
        const val MAX_CONNECTIONS = 500

        /** Must match ConfigBuilder.directTag on the Dart side. */
        const val DIRECT_OUTBOUND = "direct"
    }
}
