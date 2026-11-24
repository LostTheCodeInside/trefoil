package com.lupangoding.trefoil.core

import android.net.VpnService
import android.util.Log
import com.lupangoding.trefoil.core.UnderlyingResolver.Companion.literalAddress
import io.nekohasekai.libamnezia.Libamnezia
import io.nekohasekai.libamnezia.Logger
import io.nekohasekai.libamnezia.Protector
import io.nekohasekai.libamnezia.Resolver
import java.net.UnknownHostException
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The third core, and the narrowest.
 *
 * AmneziaWG is WireGuard with the handshake reshaped — junk packets, rewritten
 * header words, a protected header — and none of it is optional: a server configured
 * that way rejects an ordinary WireGuard handshake outright, so sing-box's own
 * WireGuard endpoint cannot be talked into carrying it.
 *
 * Rather than fork a core, it runs the same way Xray does here: a loopback SOCKS5
 * server that sing-box dials as an ordinary proxy outbound. The TUN, DNS, routing and
 * per-app handling are untouched, and there is still exactly one tunnel
 * implementation to reason about.
 */
object AmneziaRuntime {

    /**
     * Where the tunnel listened before each session drew its own port. Kept only for
     * a config written by that version, whose sing-box side still dials it.
     */
    const val LEGACY_SOCKS_PORT = 10809

    /**
     * Where the SOCKS server listens and the credentials it demands.
     *
     * Drawn fresh for every connect on the Dart side, which writes the same set into
     * the sing-box config that dials it. Loopback is reachable by every app on the
     * device, so without credentials any of them could use the tunnel and learn the
     * server it exits from.
     */
    class Socks(val port: Int, val username: String, val password: String) {
        fun toJson(): String = JSONObject()
            .put("port", port)
            .put("username", username)
            .put("password", password)
            .toString()

        // Never the password: this ends up in a log line sooner or later.
        override fun toString() = "Socks(port=$port, authenticated=${username.isNotEmpty()})"

        companion object {
            /** What a config written before the hand-off was authenticated expects. */
            val LEGACY = Socks(LEGACY_SOCKS_PORT, "", "")

            /**
             * Null for anything that is not a complete, sane set. A half-written set
             * would fail later with a far less useful error than "not configured".
             */
            fun of(port: Int?, username: String?, password: String?): Socks? {
                if (port == null || port !in 1024..65535) return null
                if (username.isNullOrEmpty() || password.isNullOrEmpty()) return null
                return Socks(port, username, password)
            }

            fun parse(json: String): Socks? = runCatching {
                val o = JSONObject(json)
                of(o.optInt("port", -1), o.optString("username"), o.optString("password"))
            }.getOrNull()
        }
    }

    private val running = AtomicBoolean(false)

    /**
     * Keeps the tunnel's own UDP sockets out of the tunnel.
     *
     * Without it the thing eats itself: the device's handshake packets are routed
     * into the TUN they are supposed to be carrying, and nothing ever reaches the
     * server. It looks like a hang rather than an error.
     */
    private class ServiceProtector(private val service: VpnService) : Protector {
        override fun protect(fd: Long): Boolean = service.protect(fd.toInt())
    }

    /**
     * Carries what the tunnel says to logcat.
     *
     * A gomobile binding's stdout goes nowhere on Android, which is where this library
     * writes by default — so a tunnel that would not come up had nothing to say about
     * why, from either side of the boundary. Under its own tag so it can be read
     * without the rest of the app's noise: `adb logcat -s AmneziaWG`.
     *
     * Every packet it handles is worth a line to it, and each line crosses the binding
     * whether or not anyone reads it. Those are left out unless debugging is on;
     * errors always come through.
     */
    private class LogcatLogger(private val verbose: Boolean) : Logger {
        override fun verbose(): Boolean = verbose

        override fun log(message: String) {
            Log.i("AmneziaWG", message)
        }
    }

    /**
     * Finds the server's address on the network underneath.
     *
     * Go's own resolver reads `/etc/resolv.conf`, which Android does not have, so a
     * config naming its server by host never came up at all.
     */
    private class ServiceResolver(service: VpnService) : Resolver {
        private val resolver = UnderlyingResolver(service)

        override fun resolve(host: String): String =
            resolver.resolve(host)
                .mapNotNull { it.literalAddress() }
                .ifEmpty { throw UnknownHostException(host) }
                .joinToString("\n")
    }

    /**
     * Starts the tunnel, replacing any previous one.
     *
     * Throws on a config the library will not accept, which is deliberate: the caller
     * aborts the connection rather than bringing up a tunnel whose proxy will never
     * answer.
     */
    fun start(service: VpnService, conf: String, socks: Socks) {
        stop()
        Libamnezia.start(
            conf,
            socks.port.toLong(),
            socks.username,
            socks.password,
            ServiceProtector(service),
            ServiceResolver(service),
            LogcatLogger(AppPrefs.debug(service)),
        )
        running.set(true)
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) {
            // Also asked of the library when we think it is already down: a start that
            // threw halfway can leave a device up with this flag never set.
            runCatching { Libamnezia.stop() }
            return
        }
        runCatching { Libamnezia.stop() }
    }

    fun isRunning(): Boolean =
        running.get() && runCatching { Libamnezia.isRunning() }.getOrDefault(false)
}
