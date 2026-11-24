package com.lupangoding.trefoil.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build

/**
 * The user's "connect on boot" preference, and the receiver that acts on it.
 *
 * Kept in preferences rather than in the profile document because the service reads
 * it from a receiver, long before any Flutter engine exists.
 */
object AutoStart {
    private const val PREFS = "trefoil_core"
    private const val KEY_ENABLED = "auto_start"
    private const val KEY_PROFILE = "auto_start_profile"
    private const val KEY_DESIRED = "tunnel_desired"

    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun profileName(context: Context): String = prefs(context).getString(KEY_PROFILE, "").orEmpty()

    /**
     * Whether the user currently wants the tunnel up.
     *
     * Distinct from [isEnabled], which is the "connect on boot" preference. This one
     * is the live intent, and it exists for one narrow case: Android recreates a
     * killed sticky service with no intent, and without this a kill that landed
     * during a disconnect would bring back the tunnel the user had just switched off.
     * Written on both edges rather than inferred, because inferring it means guessing
     * at what a missing intent meant.
     */
    fun isDesired(context: Context): Boolean = prefs(context).getBoolean(KEY_DESIRED, false)

    fun setDesired(context: Context, desired: Boolean) {
        prefs(context).edit().putBoolean(KEY_DESIRED, desired).apply()
    }

    fun rememberProfile(context: Context, profileName: String) {
        prefs(context).edit().putString(KEY_PROFILE, profileName).apply()
    }

    /**
     * Starts the tunnel if everything it needs is already in place.
     *
     * Returns false when it cannot: no saved config, or VPN consent not granted.
     * Consent cannot be requested from here — that needs an Activity — so the caller
     * has to send the user to the app instead of failing silently.
     */
    fun startIfPossible(context: Context): Boolean {
        if (!LibboxRuntime.configFile(context).isFile) return false
        if (VpnService.prepare(context) != null) return false

        val intent = Intent(context, TrefoilVpnService::class.java)
            .putExtra(TrefoilVpnService.EXTRA_PROFILE_NAME, profileName(context))
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }.isSuccess
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/**
 * Reconnects after a reboot.
 *
 * Android 12+ restricts starting a foreground service from the background, and the
 * exemptions differ by version and vendor, so this is best-effort by design: a
 * failure leaves the tunnel down rather than crashing. Users who need a guarantee
 * should use Android's own Always-on VPN setting, which this app supports by virtue
 * of being a VpnService.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        // A placed widget keeps the tap PendingIntent it was last drawn with. After an
        // update that one may point somewhere the new version no longer answers, so
        // redraw before anything else -- whether or not auto-connect is on.
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) TrefoilWidgetProvider.refresh(context)
        if (!AutoStart.isEnabled(context)) return
        AutoStart.startIfPossible(context)
    }
}
