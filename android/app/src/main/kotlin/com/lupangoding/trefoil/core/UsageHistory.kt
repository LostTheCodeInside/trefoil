package com.lupangoding.trefoil.core

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import org.json.JSONObject

/**
 * Daily upload and download totals.
 *
 * Recorded here rather than in Dart because the tunnel is expected to run with the
 * app closed — which is most of the time — and a Dart-side recorder would simply miss
 * that traffic.
 *
 * The core reports totals for the current session, so deltas are derived by
 * comparing against the previous reading; a total that went down means the session
 * restarted and the new value is itself the delta.
 */
object UsageHistory {

    /** Long enough to answer "how much this month", short enough to stay small. */
    private const val KEEP_DAYS = 90

    /** Status arrives every second; writing that often would be pointless disk churn. */
    private const val FLUSH_AFTER_MS = 30_000L

    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    private var lastUplinkTotal = 0L
    private var lastDownlinkTotal = 0L
    private var pendingUp = 0L
    private var pendingDown = 0L
    private var lastFlush = 0L

    /** Called on every status tick with the session's running totals. */
    @Synchronized
    fun observe(context: Context, uplinkTotal: Long, downlinkTotal: Long) {
        // Checked here rather than at the call site so nothing can record by another
        // route: off means no history is written at all.
        if (!AppPrefs.trafficStats(context)) return
        // A total smaller than the last means a fresh session, so it is the delta.
        val up = if (uplinkTotal >= lastUplinkTotal) uplinkTotal - lastUplinkTotal else uplinkTotal
        val down =
            if (downlinkTotal >= lastDownlinkTotal) downlinkTotal - lastDownlinkTotal else downlinkTotal
        lastUplinkTotal = uplinkTotal
        lastDownlinkTotal = downlinkTotal
        pendingUp += up
        pendingDown += down

        val now = System.currentTimeMillis()
        if (now - lastFlush >= FLUSH_AFTER_MS) flush(context)
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

        val file = file(context)
        val root = runCatching { JSONObject(file.readText()) }.getOrElse { JSONObject() }
        val today = dayFormat.format(System.currentTimeMillis())
        val day = root.optJSONObject(today) ?: JSONObject()
        day.put("up", day.optLong("up") + pendingUp)
        day.put("down", day.optLong("down") + pendingDown)
        root.put(today, day)
        pendingUp = 0
        pendingDown = 0

        prune(root)
        // Temp-then-rename: a crash mid-write would otherwise leave unparseable JSON
        // and silently lose the whole history.
        runCatching {
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeText(root.toString())
            if (!temp.renameTo(file)) temp.delete()
        }
    }

    private fun prune(root: JSONObject) {
        val cutoff = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -KEEP_DAYS) }
        val oldest = dayFormat.format(cutoff.timeInMillis)
        // Dates are ISO, so a string comparison is a date comparison.
        root.keys().asSequence().filter { it < oldest }.toList().forEach(root::remove)
    }

    fun file(context: Context) = File(context.applicationContext.filesDir, "usage-history.json")
}
