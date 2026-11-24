package com.lupangoding.trefoil.core

import android.content.Context

/**
 * What Android last told us about always-on VPN.
 *
 * Android exposes this only to a *running* VpnService, and only from API 29: an app
 * cannot ask on its own behalf. So the service records it while the tunnel is up,
 * and the answer is kept here for the settings screen to read afterwards.
 *
 * Persisted rather than held in memory because the answer outlives the process that
 * learned it: the service is what can ask, the UI is what shows it, and Android is
 * free to kill either between those two moments.
 *
 * This is a report, never a control. Always-on and its lockdown are set in the
 * system settings and nowhere else — an app that could switch off its own kill
 * switch would not be a kill switch.
 */
object AlwaysOn {
    private const val PREFS = "trefoil_core"
    private const val KEY_KNOWN = "always_on_known"
    private const val KEY_ACTIVE = "always_on_active"
    private const val KEY_LOCKDOWN = "always_on_lockdown"

    fun record(context: Context, active: Boolean, lockdown: Boolean) {
        prefs(context).edit()
            .putBoolean(KEY_KNOWN, true)
            .putBoolean(KEY_ACTIVE, active)
            .putBoolean(KEY_LOCKDOWN, lockdown)
            .apply()
    }

    /**
     * `known` is false until a tunnel has run at least once on API 29+, which is the
     * difference between "it is off" and "we have not been in a position to look".
     *
     * Even once known, a false [KEY_ACTIVE] is the weaker claim of the two: Android
     * reports this per running service instance, so a tunnel the user started by
     * hand may read false while always-on is configured all the same. A true reading
     * can be trusted; a false one is reported as "not seen", never as "off".
     */
    fun status(context: Context): Map<String, Any?> = prefs(context).let { prefs ->
        mapOf(
            "known" to prefs.getBoolean(KEY_KNOWN, false),
            "active" to prefs.getBoolean(KEY_ACTIVE, false),
            "lockdown" to prefs.getBoolean(KEY_LOCKDOWN, false),
        )
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
