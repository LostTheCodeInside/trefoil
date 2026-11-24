package com.lupangoding.trefoil.core

import android.content.Context
import java.io.File
import org.json.JSONObject

/**
 * Lifetime upload and download per server.
 *
 * The connect screen's counters are the session's, and a session ends at every
 * reconnect — which is often, since most settings only take effect on one. That
 * makes them useless for the question people actually ask of a server list: which of
 * these have I been using, and how much.
 *
 * Recorded here rather than in Dart for the same reason the daily history is: the
 * tunnel is expected to run with the app closed, and a Dart-side recorder would miss
 * exactly the traffic worth counting. Dart only reads it, from ServerUsageStore.
 */
object ServerUsage {

    /** Status arrives every second; writing that often would be pointless churn. */
    private const val FLUSH_AFTER_MS = 30_000L

    /**
     * Servers to remember, at most.
     *
     * A subscription can be replaced wholesale, and each import brings new names, so
     * without a ceiling this grows for as long as the app is installed. The smallest
     * totals go first: they are the ones nobody is looking for.
     */
    private const val KEEP_SERVERS = 300

    private var lastUplinkTotal = 0L
    private var lastDownlinkTotal = 0L
    private var pendingUp = 0L
    private var pendingDown = 0L
    private var lastFlush = 0L

    /**
     * Which server the traffic belongs to.
     *
     * Updated from the core's own group reports rather than taken from the profile
     * the tunnel was started with: a live switch changes the server without
     * restarting anything, and attributing the rest of the session to the previous
     * one would be quietly wrong.
     */
    @Volatile
    private var active: String = ""

    @Synchronized
    fun setActive(context: Context, tag: String) {
        if (tag == active) return
        // Flush first: what has accumulated belongs to the server that carried it.
        flush(context)
        active = tag
    }

    /** Called on every status tick with the session's running totals. */
    @Synchronized
    fun observe(context: Context, uplinkTotal: Long, downlinkTotal: Long) {
        if (!AppPrefs.trafficStats(context)) return
        // A total smaller than the last means a fresh session, so it is the delta.
        val up = if (uplinkTotal >= lastUplinkTotal) uplinkTotal - lastUplinkTotal else uplinkTotal
        val down =
            if (downlinkTotal >= lastDownlinkTotal) downlinkTotal - lastDownlinkTotal else downlinkTotal
        lastUplinkTotal = uplinkTotal
        lastDownlinkTotal = downlinkTotal
        pendingUp += up
        pendingDown += down

        if (System.currentTimeMillis() - lastFlush >= FLUSH_AFTER_MS) flush(context)
    }

    /** Writes what has accumulated and starts a new session's counting. */
    @Synchronized
    fun reset(context: Context) {
        flush(context)
        lastUplinkTotal = 0
        lastDownlinkTotal = 0
    }

    @Synchronized
    fun flush(context: Context) {
        lastFlush = System.currentTimeMillis()
        if (pendingUp == 0L && pendingDown == 0L) return
        // Nowhere to put it. Dropped rather than guessed at: a total under the wrong
        // server is worse than one that is a little short.
        if (active.isEmpty()) {
            pendingUp = 0
            pendingDown = 0
            return
        }

        val file = file(context)
        val root = runCatching { JSONObject(file.readText()) }.getOrElse { JSONObject() }
        val server = root.optJSONObject(active) ?: JSONObject()
        server.put("up", server.optLong("up") + pendingUp)
        server.put("down", server.optLong("down") + pendingDown)
        root.put(active, server)
        pendingUp = 0
        pendingDown = 0

        prune(root)
        // Temp-then-rename: a crash mid-write would otherwise leave unparseable JSON
        // and silently lose every total.
        runCatching {
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeText(root.toString())
            if (!temp.renameTo(file)) temp.delete()
        }
    }

    /** Forgets one server, for when it is removed from the list. */
    @Synchronized
    fun forget(context: Context, tag: String) {
        val file = file(context)
        if (!file.isFile) return
        val root = runCatching { JSONObject(file.readText()) }.getOrElse { return }
        if (!root.has(tag)) return
        root.remove(tag)
        runCatching {
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeText(root.toString())
            if (!temp.renameTo(file)) temp.delete()
        }
    }

    private fun prune(root: JSONObject) {
        if (root.length() <= KEEP_SERVERS) return
        val byTotal = root.keys().asSequence().map { tag ->
            val entry = root.optJSONObject(tag)
            tag to (entry?.optLong("up").orZero() + entry?.optLong("down").orZero())
        }.sortedBy { it.second }.toList()
        byTotal.take(root.length() - KEEP_SERVERS).forEach { root.remove(it.first) }
    }

    private fun Long?.orZero(): Long = this ?: 0L

    fun file(context: Context) = File(context.applicationContext.filesDir, "server-usage.json")
}
