package com.lupangoding.trefoil.core

import android.content.Context
import android.net.ConnectivityManager
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.UnknownHostException

/**
 * Resolves names using Android's own resolver, on behalf of sing-box's `local` DNS
 * server type.
 *
 * Without this, sing-box falls back to its generic Unix implementation, which reads
 * `/etc/resolv.conf` — a file Android does not have. The `local` server then resolves
 * nothing, and because it is the config's `default_domain_resolver`, the core cannot
 * resolve the proxy server's own hostname. The tunnel comes up and no traffic flows.
 *
 * The lookup is deliberately pinned to a non-VPN network. Our own app's traffic is
 * routed into the tunnel we are bringing up, so resolving on the default network
 * would mean the proxy's address can only be found once the proxy already works.
 */
class LocalDnsTransport(private val context: Context) : LocalDNSTransport {

    private val probe by lazy {
        NetworkProbe(context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager)
    }

    /**
     * False, so sing-box asks for a plain hostname lookup instead of handing us a
     * wire-format DNS message. Android's public resolver API is address-based; doing
     * raw exchanges would mean building our own DNS client for no benefit.
     */
    override fun raw(): Boolean = false

    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        // Unreachable while raw() is false; sing-box picks one path or the other.
        throw UnsupportedOperationException("raw DNS exchange is not implemented")
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        // sing-box passes an FQDN; Android's resolver wants it without the root dot.
        val host = domain.trimEnd('.')
        if (host.isEmpty()) {
            ctx.errorCode(RCODE_NAME_ERROR)
            return
        }
        try {
            val resolved = resolve(host)
            val matching = resolved.filter {
                when (network) {
                    "ip4" -> it is Inet4Address
                    "ip6" -> it is Inet6Address
                    else -> true
                }
            }
            // A host with only A records answering a AAAA query is an empty NOERROR,
            // not a failure; reporting NXDOMAIN here would poison the other family.
            ctx.success(matching.mapNotNull { it.literalAddress() }.joinToString("\n"))
        } catch (_: UnknownHostException) {
            ctx.errorCode(RCODE_NAME_ERROR)
        } catch (_: Throwable) {
            ctx.errorCode(RCODE_SERVER_FAILURE)
        }
    }

    private fun resolve(host: String): List<InetAddress> {
        val underlying = probe.bestNonVpnNetwork()
        return if (underlying != null) {
            underlying.getAllByName(host).toList()
        } else {
            // No usable non-VPN network. Falling back to the global resolver is still
            // worth trying: before the tunnel is established it behaves normally.
            InetAddress.getAllByName(host).toList()
        }
    }

    private companion object {
        /** DNS RCODEs, as sing-box maps ExchangeContext.errorCode straight to one. */
        const val RCODE_SERVER_FAILURE = 2
        const val RCODE_NAME_ERROR = 3

        /**
         * sing-box parses these back into addresses, and a link-local IPv6 scope
         * suffix ("%wlan0") is not something it accepts.
         */
        fun InetAddress.literalAddress(): String? = hostAddress?.substringBefore('%')
    }
}
