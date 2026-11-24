package com.lupangoding.trefoil.core

import android.content.Context
import android.content.res.Configuration
import androidx.annotation.StringRes
import java.util.Locale

/**
 * The language the native side speaks: the one chosen in the app, else the device's.
 *
 * The notification, the Quick Settings tile and the widget are drawn here, often with
 * no Flutter engine running at all — after a reboot, or with the app swiped away — so
 * they cannot ask Dart for a translation. They read Android resources instead,
 * through a context set to whatever language the app was last told to use.
 */
object AppLocale {

    /** The last context built, keyed by the tag it was built for. */
    @Volatile
    private var cached: Pair<String, Context>? = null

    fun context(base: Context): Context {
        val app = base.applicationContext ?: base
        // Following the device needs nothing: the application's own resources
        // already track the system language, including a change made while running.
        val tag = AppPrefs.localeTag(app) ?: return app
        cached?.let { (builtFor, context) -> if (builtFor == tag) return context }
        val locale = Locale.forLanguageTag(tag)
        val config = Configuration(app.resources.configuration).apply {
            setLocale(locale)
            setLayoutDirection(locale)
        }
        return app.createConfigurationContext(config).also { cached = tag to it }
    }

    fun string(base: Context, @StringRes id: Int): String = context(base).getString(id)
}
