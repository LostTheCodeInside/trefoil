package com.lupangoding.trefoil.core

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * Brings the tunnel back after the whole process has been killed.
 *
 * A sticky service was meant to, and does not. The TUN device goes when the process
 * does, the system unbinds the VPN service on seeing it go, and a service it has failed
 * to unbind is one it no longer restarts.
 *
 * So the running tunnel keeps pushing an alarm out of its own reach, and the alarm goes
 * off only once nothing is left to push it. It does not wake the phone: asleep, there is
 * nothing to carry. A force stop takes the alarm along, as it should.
 */
object Revival {
    const val EVERY_MS = 45_000L
    private const val DUE_MS = 2 * EVERY_MS

    /** How long a tunnel has to last to have nothing to do with the last kill. */
    const val SETTLED_MS = 10 * 60_000L

    /** Kills in a row after which the tunnel is left down. */
    private const val LIMIT = 5
    private const val PREFS = "trefoil_revival"
    private const val KEY_ATTEMPTS = "attempts"

    fun postpone(context: Context) {
        runCatching {
            alarms(context).set(
                AlarmManager.ELAPSED_REALTIME,
                SystemClock.elapsedRealtime() + DUE_MS,
                alarm(context),
            )
        }
    }

    fun cancel(context: Context) {
        runCatching { alarms(context).cancel(alarm(context)) }
        settled(context)
    }

    fun settled(context: Context) {
        prefs(context).edit().remove(KEY_ATTEMPTS).apply()
    }

    /** Whether to try once more; every yes is counted. */
    fun mayTry(context: Context): Boolean {
        val made = prefs(context).getInt(KEY_ATTEMPTS, 0)
        if (made >= LIMIT) return false
        // Committed: what is being counted is a process that keeps dying.
        prefs(context).edit().putInt(KEY_ATTEMPTS, made + 1).commit()
        return true
    }

    private fun alarms(context: Context) = context.getSystemService(AlarmManager::class.java)

    private fun alarm(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, RevivalReceiver::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/** The alarm going off; see [Revival]. */
class RevivalReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!AutoStart.isDesired(context)) return
        // The process outlived the alarm: the phone was asleep, and the pushing with it.
        if (ServiceState.current.stage != TunnelStage.STOPPED) return Revival.postpone(context)
        if (Revival.mayTry(context)) {
            AutoStart.startIfPossible(context)
        } else {
            AutoStart.setDesired(context, false)
        }
    }
}
