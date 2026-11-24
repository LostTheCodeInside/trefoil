package com.lupangoding.trefoil.core

import android.content.Context
import java.security.SecureRandom

/**
 * Shared secret for libbox's command server.
 *
 * The command server listens on a socket only this app can open, and asks for this on
 * top of it: attaching to our core means reading the traffic log and issuing commands,
 * so it should take more than one thing going wrong. Generated with a CSPRNG, persisted
 * with private-mode permissions, and never leaves the device.
 */
object CommandSecret {
    private const val PREFS = "trefoil_core"
    private const val KEY = "command_secret"

    @Volatile
    private var cached: String? = null

    fun get(context: Context): String {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            // MODE_PRIVATE keeps the file readable only by this app's UID.
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val existing = prefs.getString(KEY, null)
            val secret = if (existing.isNullOrEmpty()) {
                val bytes = ByteArray(32)
                SecureRandom().nextBytes(bytes)
                bytes.joinToString("") { "%02x".format(it) }
                    .also { prefs.edit().putString(KEY, it).apply() }
            } else {
                existing
            }
            cached = secret
            return secret
        }
    }
}
