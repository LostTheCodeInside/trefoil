package com.lupangoding.trefoil.core

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import io.nekohasekai.libbox.Libbox
import java.net.NetworkInterface as JavaNetworkInterface

/**
 * Finds the real network underneath our tunnel.
 *
 * Every question the core asks about "the network" has to be answered about the
 * physical link, never about our own TUN. Android does not make that easy: once a
 * VpnService is running, the app's own default network *is* the VPN, so the obvious
 * APIs point straight back at us.
 *
 * Getting this wrong is not subtle. sing-box matches the default interface against
 * its interface list by index, and it removes our TUN from that list first — so
 * reporting the TUN as default leaves nothing to match, and every single dial fails
 * with "no available network interface".
 */
internal class NetworkProbe(private val connectivity: ConnectivityManager) {

    /**
     * The best usable non-VPN network, or null when the device is offline.
     *
     * Prefers one the system has validated as actually reaching the internet, and
     * keeps an unvalidated candidate in reserve for captive portals and the moments
     * during a WIFI/cellular handover when nothing is validated yet.
     */
    fun bestNonVpnNetwork(): Network? {
        @Suppress("DEPRECATION")
        val candidates = runCatching { connectivity.allNetworks }.getOrNull() ?: return null
        var fallback: Network? = null
        for (network in candidates) {
            val caps = capabilitiesOf(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return network
            if (fallback == null) fallback = network
        }
        return fallback
    }

    /** Whether what this app would use by default is a tunnel, ours included. */
    fun activeIsVpn(): Boolean {
        val active = runCatching { connectivity.activeNetwork }.getOrNull() ?: return false
        return capabilitiesOf(active)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
    }

    fun capabilitiesOf(network: Network): NetworkCapabilities? =
        runCatching { connectivity.getNetworkCapabilities(network) }.getOrNull()

    fun interfaceNameOf(network: Network): String? =
        runCatching { connectivity.getLinkProperties(network)?.interfaceName }.getOrNull()

    /** Maps each non-VPN network's interface name to the type sing-box uses in rules. */
    fun interfaceTypes(): Map<String, Int> {
        @Suppress("DEPRECATION")
        val candidates = runCatching { connectivity.allNetworks }.getOrNull() ?: return emptyMap()
        val types = mutableMapOf<String, Int>()
        for (network in candidates) {
            val caps = capabilitiesOf(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            val name = interfaceNameOf(network) ?: continue
            types[name] = caps.toBoxInterfaceType()
        }
        return types
    }

    companion object {
        /**
         * The kernel interface index, which is what sing-box matches on. Returns -1
         * when the name cannot be resolved; callers must treat that as "unknown"
         * rather than reporting it, since no real interface will ever match -1.
         */
        fun interfaceIndex(name: String): Int =
            runCatching { JavaNetworkInterface.getByName(name)?.index ?: -1 }.getOrDefault(-1)

        fun NetworkCapabilities.toBoxInterfaceType(): Int = when {
            hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
            hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
            hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
            else -> Libbox.InterfaceTypeOther
        }
    }
}
