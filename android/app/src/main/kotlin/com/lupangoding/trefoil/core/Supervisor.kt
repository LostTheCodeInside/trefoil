package com.lupangoding.trefoil.core

import kotlin.math.min

/**
 * When a core that has stopped reporting should be restarted, and when to give up.
 *
 * Deliberately pure: no Android, no coroutines, no clock of its own. A restart policy
 * that is wrong is worse than having none — it turns one failure into a loop that
 * burns battery and keeps the tunnel permanently half-up — so the whole of it is one
 * readable object with the time passed in, rather than decisions scattered through a
 * service that also owns a TUN device.
 *
 * Not thread-safe by design; it is only ever touched from the service's single-
 * threaded scope.
 */
internal class Supervisor(
    /** Give up after this many restarts in a row without a healthy stretch between. */
    private val maxAttempts: Int = 5,
    private val firstDelayMs: Long = 2_000,
    private val maxDelayMs: Long = 32_000,
    /** How long the core must report normally before the attempt count resets. */
    private val healthyForMs: Long = 120_000,
) {
    private var attempts = 0
    private var lastRestartAt = 0L

    /**
     * The core is alive at [now].
     *
     * A tunnel that has run normally for a while has recovered, and the next failure
     * should get the full budget again rather than inheriting an exhausted one from
     * a bad hour earlier in the day.
     */
    fun onHealthy(now: Long) {
        if (attempts > 0 && now - lastRestartAt >= healthyForMs) {
            attempts = 0
            lastRestartAt = 0L
        }
    }

    /**
     * How long to wait before the next restart, or null to stop trying.
     *
     * Null is a real answer, not a failure to produce one: something is wrong that
     * restarting does not fix, and the honest response is to stop and say so rather
     * than to keep cycling a tunnel that will not come up.
     */
    fun nextDelayMs(now: Long): Long? {
        if (attempts >= maxAttempts) return null
        lastRestartAt = now
        val delay = firstDelayMs shl attempts
        attempts++
        return min(delay, maxDelayMs)
    }

    /**
     * Whether the core has gone quiet.
     *
     * The reporting interval is a user setting between one and ten seconds, so the
     * threshold is derived from it rather than fixed: five missed reports, and never
     * less than twenty seconds, which is longer than any pause a busy device causes
     * and far shorter than someone would sit staring at a dead tunnel.
     */
    fun isStale(now: Long, lastReportAt: Long, intervalSeconds: Int): Boolean {
        if (lastReportAt <= 0L) return false
        return now - lastReportAt > staleAfterMs(intervalSeconds)
    }

    fun staleAfterMs(intervalSeconds: Int): Long =
        maxOf(MIN_STALE_MS, intervalSeconds.coerceAtLeast(1) * 5_000L)

    private companion object {
        const val MIN_STALE_MS = 20_000L
    }
}
