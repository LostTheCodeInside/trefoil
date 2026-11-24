package com.lupangoding.trefoil.core

import android.content.Context

/**
 * Preferences the service needs but the profile document cannot carry.
 *
 * The tunnel is expected to run with the app closed, so anything the service reads
 * has to be somewhere it can reach without a Flutter engine. The profile document is
 * read by Dart only; these are not.
 */
object AppPrefs {
    private const val PREFS = "trefoil_core"
    private const val KEY_SPEED_IN_NOTIFICATION = "notification_speed"
    private const val KEY_MEMORY_LIMIT = "memory_limit"
    private const val KEY_LABEL_PROXY = "label_proxy"
    private const val KEY_LABEL_DIRECT = "label_direct"
    private const val KEY_NOTIFICATION_INTERVAL = "notification_interval"
    private const val KEY_METERED = "metered"
    private const val KEY_WAKE_LOCK = "wake_lock"
    private const val KEY_TRAFFIC_STATS = "traffic_stats"
    private const val KEY_RESET_NETWORK = "reset_on_network_change"
    private const val KEY_RESET_WAKE = "reset_on_wake"
    private const val KEY_GROUP_IN_NOTIFICATION = "group_in_notification"
    private const val KEY_LABEL_GROUP = "label_group"
    private const val KEY_DEBUG = "debug_mode"
    private const val KEY_LOCALE = "locale_tag"
    private const val KEY_CONFIG_VERSION = "config_version"

    /** The languages with a translation in res/values-*. Anything else follows the device. */
    private val SHIPPED_LOCALES = setOf("en", "ar", "fa", "id", "ru", "tr", "vi", "zh")

    /** The notification shows no throughput at all. */
    const val SPEED_OFF = "off"

    /** One up and one down figure, from the core's aggregate counters. */
    const val SPEED_TOTAL = "total"

    /**
     * Proxy and direct separately.
     *
     * Costs more than the other two: the aggregate counters carry no breakdown by
     * outbound, so this needs the core's per-connection feed running for as long as
     * the tunnel is up — with the app closed as well. Which is why it is a choice
     * rather than the default.
     */
    const val SPEED_SPLIT = "split"

    /** What the ongoing notification shows: one of the three constants above. */
    fun notificationSpeed(context: Context): String =
        prefs(context).getString(KEY_SPEED_IN_NOTIFICATION, SPEED_TOTAL) ?: SPEED_TOTAL

    fun setNotificationSpeed(context: Context, mode: String) {
        // Allow-listed rather than trusted: an unknown value would leave the
        // notification in a state nothing knows how to render.
        val safe = when (mode) {
            SPEED_OFF, SPEED_TOTAL, SPEED_SPLIT -> mode
            else -> SPEED_TOTAL
        }
        prefs(context).edit().putString(KEY_SPEED_IN_NOTIFICATION, safe).apply()
    }

    /**
     * Trades throughput for a smaller heap.
     *
     * Applied live rather than at setup, so it is worth reaching for exactly when it
     * is needed: the app is being killed for memory and the user is looking for
     * something to try.
     */
    fun memoryLimit(context: Context): Boolean = prefs(context).getBoolean(KEY_MEMORY_LIMIT, false)

    fun setMemoryLimit(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_MEMORY_LIMIT, enabled).apply()
    }

    /**
     * libbox's own debug instrumentation.
     *
     * Read once, when the core is first set up in this process — `Libbox.setup` is
     * process-global and runs exactly once — so a change only lands after the app is
     * restarted. The UI says so rather than pretending otherwise.
     */
    fun debug(context: Context): Boolean = prefs(context).getBoolean(KEY_DEBUG, false)

    fun setDebug(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_DEBUG, enabled).apply()
    }

    /**
     * Translations of "Proxy" and "Direct" for the notification.
     *
     * The service has no Flutter engine to ask, and after a reboot there is not even
     * an app process — so the app hands these over whenever it starts the tunnel and
     * they are kept for the times it cannot. English is the fallback, which is what
     * the notification said in every language before this.
     */
    fun proxyLabel(context: Context): String =
        prefs(context).getString(KEY_LABEL_PROXY, "Proxy").orEmpty().ifEmpty { "Proxy" }

    fun directLabel(context: Context): String =
        prefs(context).getString(KEY_LABEL_DIRECT, "Direct").orEmpty().ifEmpty { "Direct" }

    fun rememberLabels(context: Context, proxy: String, direct: String) {
        prefs(context).edit()
            .putString(KEY_LABEL_PROXY, proxy)
            .putString(KEY_LABEL_DIRECT, direct)
            .apply()
    }

    /**
     * Seconds between notification updates.
     *
     * Every tick wakes the core, formats a string and posts a notification. Once a
     * second reads as live; less often costs proportionally less for a readout
     * nobody is watching most of the time.
     */
    fun notificationIntervalSeconds(context: Context): Int =
        prefs(context).getInt(KEY_NOTIFICATION_INTERVAL, 1).coerceIn(1, 10)

    fun setNotificationIntervalSeconds(context: Context, seconds: Int) {
        prefs(context).edit().putInt(KEY_NOTIFICATION_INTERVAL, seconds.coerceIn(1, 10)).apply()
    }

    /**
     * Report the tunnel to Android as a metered link.
     *
     * Android then treats it the way it treats mobile data: background sync backs
     * off, and apps that check before downloading something large will ask first.
     */
    fun metered(context: Context): Boolean = prefs(context).getBoolean(KEY_METERED, false)

    fun setMetered(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_METERED, enabled).apply()
    }

    /**
     * Hold a partial wake lock for as long as the tunnel is up.
     *
     * Costs battery by design. It is here because some vendors suspend the CPU
     * aggressively enough that the tunnel stalls with the screen off, and this is
     * the only lever the app has against that.
     */
    fun wakeLock(context: Context): Boolean = prefs(context).getBoolean(KEY_WAKE_LOCK, false)

    fun setWakeLock(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_WAKE_LOCK, enabled).apply()
    }

    /** Whether daily usage totals are recorded at all. */
    fun trafficStats(context: Context): Boolean =
        prefs(context).getBoolean(KEY_TRAFFIC_STATS, true)

    fun setTrafficStats(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_TRAFFIC_STATS, enabled).apply()
    }

    /** Close open connections when the underlying network changes. */
    fun resetOnNetworkChange(context: Context): Boolean =
        prefs(context).getBoolean(KEY_RESET_NETWORK, false)

    fun setResetOnNetworkChange(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_RESET_NETWORK, enabled).apply()
    }

    /** Close open connections when the device wakes. */
    fun resetOnWake(context: Context): Boolean = prefs(context).getBoolean(KEY_RESET_WAKE, false)

    fun setResetOnWake(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_RESET_WAKE, enabled).apply()
    }

    /** Whether the notification names the subscription a server came from. */
    fun groupInNotification(context: Context): Boolean =
        prefs(context).getBoolean(KEY_GROUP_IN_NOTIFICATION, false)

    fun setGroupInNotification(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_GROUP_IN_NOTIFICATION, enabled).apply()
    }

    /** The subscription the running profile came from, empty when it came from none. */
    fun groupName(context: Context): String = prefs(context).getString(KEY_LABEL_GROUP, "").orEmpty()

    fun rememberGroupName(context: Context, name: String) {
        prefs(context).edit().putString(KEY_LABEL_GROUP, name).apply()
    }

    /**
     * Which generation of config the saved one is, as the app numbers them; 0 for one
     * written before this was recorded. Lets the app tell a tunnel still running an
     * old config after an update, which only a reconnect replaces.
     */
    fun configVersion(context: Context): Int = prefs(context).getInt(KEY_CONFIG_VERSION, 0)

    fun rememberConfigVersion(context: Context, version: Int) {
        prefs(context).edit().putInt(KEY_CONFIG_VERSION, version.coerceAtLeast(0)).apply()
    }

    /** The language chosen inside the app, or null to follow the device. */
    fun localeTag(context: Context): String? = prefs(context).getString(KEY_LOCALE, null)

    fun setLocaleTag(context: Context, tag: String?) {
        // Allow-listed rather than trusted: a tag with no translation behind it would
        // silently fall back to English while the app itself showed something else.
        val safe = tag?.takeIf { it in SHIPPED_LOCALES }
        prefs(context).edit().apply {
            if (safe == null) remove(KEY_LOCALE) else putString(KEY_LOCALE, safe)
        }.apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
