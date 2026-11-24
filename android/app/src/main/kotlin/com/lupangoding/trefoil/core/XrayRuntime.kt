package com.lupangoding.trefoil.core

import android.net.VpnService
import io.nekohasekai.libxray.Libxray
import io.nekohasekai.libxray.Protector
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The second core.
 *
 * sing-box carries every tunnel; Xray only appears for servers sing-box cannot
 * speak to — today that means post-quantum REALITY. When it is needed it runs as a
 * loopback SOCKS5 server and sing-box dials it as an ordinary proxy outbound, so the
 * TUN, DNS, routing and per-app handling are untouched and there is exactly one
 * tunnel implementation to reason about.
 */
object XrayRuntime {

    private val running = AtomicBoolean(false)

    /**
     * Keeps Xray's own sockets out of the tunnel.
     *
     * Xray dials the real proxy server. Our app's traffic is routed into the TUN, so
     * an unprotected socket here would be fed straight back into sing-box, which
     * would forward it to Xray again — a loop that looks like a hang, not an error.
     */
    private class ServiceProtector(private val service: VpnService) : Protector {
        override fun protect(fd: Int): Boolean = service.protect(fd)
    }

    /**
     * Starts Xray, replacing any previous instance.
     *
     * Throws on a bad config, which is deliberate: the caller aborts the connection
     * rather than bringing up a tunnel whose proxy will never answer.
     */
    fun start(service: VpnService, configJson: String) {
        Libxray.start(configJson, ServiceProtector(service))
        running.set(true)
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        runCatching { Libxray.stop() }
    }

    fun isRunning(): Boolean = running.get() && runCatching { Libxray.isRunning() }.getOrDefault(false)

    fun version(): String = runCatching { Libxray.version() }.getOrDefault("unknown")
}
