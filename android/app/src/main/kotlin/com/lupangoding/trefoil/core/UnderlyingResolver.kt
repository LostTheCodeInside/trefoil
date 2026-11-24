package com.lupangoding.trefoil.core

import android.content.Context
import android.net.ConnectivityManager
import java.io.IOException
import java.net.InetAddress
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Future
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Looks names up on the network underneath the tunnel, for whoever is bringing the
 * tunnel up.
 *
 * Our own traffic is routed into that tunnel, so a lookup left to the default network
 * would find the server's address only once the server was already reachable.
 *
 * Android's resolver takes as long as it likes and cannot be interrupted. On a network
 * that swallows DNS that is most of a minute for every name, and each lookup held a
 * thread for all of it, as many as there were connections asking. So the lookups run
 * on a pool of fixed size and nobody waits for one past [TIMEOUT_SECONDS].
 */
internal class UnderlyingResolver(context: Context) {

    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val probe = NetworkProbe(connectivity)

    /**
     * Throws [java.net.UnknownHostException] when the name does not resolve, and
     * anything else when it could not be asked about.
     *
     * [onStarted] is handed the lookup, to be cancelled if the answer stops mattering.
     */
    fun resolve(host: String, onStarted: (Future<*>) -> Unit = {}): List<InetAddress> {
        val network = probe.bestNonVpnNetwork()
        // With nothing underneath there is still the system resolver, unless the
        // network it would use is this tunnel: that question comes straight back here.
        if (network == null && probe.activeIsVpn()) throw IOException("no network under the tunnel")
        val lookup = pool.submit(
            Callable { network?.getAllByName(host) ?: InetAddress.getAllByName(host) },
        )
        onStarted(lookup)
        try {
            return lookup.get(TIMEOUT_SECONDS, TimeUnit.SECONDS).toList()
        } catch (e: ExecutionException) {
            throw e.cause ?: e
        } finally {
            lookup.cancel(true)
        }
    }

    companion object {
        private const val THREADS = 16
        private const val WAITING = 128

        /** What the core itself allows a DNS query. */
        private const val TIMEOUT_SECONDS = 10L

        /** Full means refused rather than queued without end: the core asks again. */
        private val pool = ThreadPoolExecutor(
            THREADS,
            THREADS,
            30L,
            TimeUnit.SECONDS,
            LinkedBlockingQueue(WAITING),
        ).apply { allowCoreThreadTimeOut(true) }

        /**
         * The cores parse these back into addresses, and a link-local IPv6 scope
         * suffix ("%wlan0") is not something they accept.
         */
        fun InetAddress.literalAddress(): String? = hostAddress?.substringBefore('%')
    }
}
