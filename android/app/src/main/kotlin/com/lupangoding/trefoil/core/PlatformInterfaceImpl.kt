package com.lupangoding.trefoil.core

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.ProxyInfo
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import androidx.core.content.ContextCompat
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.util.concurrent.ConcurrentHashMap
import io.nekohasekai.libbox.NetworkInterface as BoxNetworkInterface
import java.net.NetworkInterface as JavaNetworkInterface

/**
 * Everything sing-box cannot do for itself on Android.
 *
 * The Go core runs unprivileged inside our process, so anything needing an Android
 * permission or a system service is called back out to here: creating the TUN device,
 * protecting sockets from the tunnel's own routes, resolving which app owns a
 * connection, and watching for the default network changing.
 *
 * Every method is invoked from a Go-owned thread, never the main thread. Throwing
 * here surfaces as a Go error and aborts service start, so failures that are merely
 * "unsupported on this device" must degrade instead of throwing.
 */
class PlatformInterfaceImpl(private val service: TrefoilVpnService) : PlatformInterface {

    private val context: Context get() = service
    private val connectivity by lazy {
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    /** Held so the fd stays open for the tunnel's lifetime; Go works on a dup of it. */
    @Volatile
    private var tunDescriptor: ParcelFileDescriptor? = null

    /** The previous tunnel's, still holding the phone's traffic while the next starts. */
    @Volatile
    private var heldDescriptor: ParcelFileDescriptor? = null

    /** What the device now open was opened with; see [openTun]. */
    @Volatile
    private var openPlan: TunPlan? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var updateListener: InterfaceUpdateListener? = null
    private val probe by lazy { NetworkProbe(connectivity) }

    /**
     * uid to the packages that share it, for [findConnectionOwner].
     *
     * sing-box resolves the owning app for *every* connection on Android -- that is
     * hardcoded upstream, not something the config can switch off -- and its own
     * cache is keyed by source port, so a new connection always misses it. That left
     * two blocking binder calls on the path of every connection setup, of which this
     * one asks a question whose answer does not change: a uid's package list is
     * fixed until something is installed or removed.
     */
    private val packagesByUid = ConcurrentHashMap<Int, List<String>>()

    /**
     * Cleared wholesale when any package changes.
     *
     * Correctness rather than tidiness: routing rules can match on package name, so a
     * stale entry would not merely mislabel a row in the connections list, it would
     * send an app's traffic the wrong way. Uids are also reused after an uninstall.
     */
    private val packageChanges = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = packagesByUid.clear()
    }

    private var packageChangesRegistered = false

    // ---- TUN -------------------------------------------------------------

    /**
     * Opens the device, or carries on with the one being replaced when nothing about it
     * would be different.
     *
     * Which is most reconnects, and the only way to make one without a gap: Android
     * takes the old device down before it has moved the phone's routes to a new one, and
     * for that moment every app is on the bare network.
     */
    override fun openTun(options: TunOptions): Int {
        val plan = planFor(options)
        // A reload opens a second device without anyone having closed the first.
        holdTun()
        val held = heldDescriptor
        if (held != null && plan == openPlan && isUp(plan)) {
            heldDescriptor = null
            tunDescriptor = held
            return held.fd
        }
        val pfd = builderFor(plan).establish()
            ?: error("VPN permission was revoked, or another VPN took over")
        tunDescriptor = pfd
        openPlan = plan
        releaseHeldTun()
        return pfd.fd
    }

    /** Everything a device is opened with, so that two can be told apart. */
    private data class TunPlan(
        val mtu: Int,
        val addresses: List<Pair<String, Int>>,
        val routes: List<Pair<String, Int>>,
        val dns: List<String>,
        /** With the uid each had, which a reinstall changes while the name stays. */
        val include: List<Pair<String, Int>>,
        val exclude: List<Pair<String, Int>>,
        val httpProxy: Triple<String, Int, List<String>>?,
        val metered: Boolean,
        val bypassable: Boolean,
    )

    private fun planFor(options: TunOptions): TunPlan {
        // Each getter hands back a fresh single-pass cursor, so bind once and reuse.
        val inet4 = options.inet4Address.toList().map { it.address() to it.prefix() }
        val inet6 = options.inet6Address.toList().map { it.address() to it.prefix() }
        val routes = mutableListOf<Pair<String, Int>>()
        val dns = mutableListOf<String>()
        if (options.autoRoute) {
            // RouteRange is sing-box's already-computed final route set: it folds in
            // the configured route addresses minus the excluded ones. Re-deriving it
            // from the raw route/exclude lists here would risk disagreeing with the core.
            val v4 = options.inet4RouteRange.toList().map { it.address() to it.prefix() }
            val v6 = options.inet6RouteRange.toList().map { it.address() to it.prefix() }
            routes += v4
            routes += v6
            if (v4.isEmpty() && inet4.isNotEmpty()) routes += "0.0.0.0" to 0
            if (v6.isEmpty() && inet6.isNotEmpty()) routes += "::" to 0
            // A list from sing-box 1.14 on, where it was a single address.
            runCatching {
                val servers = options.getDNSServerAddress()
                while (servers.hasNext()) dns += servers.next()
            }
        }
        return TunPlan(
            mtu = options.getMTU(),
            addresses = inet4 + inet6,
            routes = routes,
            dns = dns,
            include = options.includePackage.toList().map { it to uidOf(it) },
            exclude = options.excludePackage.toList().map { it to uidOf(it) },
            httpProxy = if (options.isHTTPProxyEnabled()) {
                Triple(
                    options.getHTTPProxyServer(),
                    options.getHTTPProxyServerPort(),
                    options.getHTTPProxyBypassDomain().toList(),
                )
            } else {
                null
            },
            metered = AppPrefs.metered(service),
            bypassable = !options.strictRoute,
        )
    }

    private fun builderFor(plan: TunPlan): VpnService.Builder {
        val builder = service.Builder().setSession(TUN_SESSION).setMtu(plan.mtu)
        plan.addresses.forEach { (address, prefix) -> builder.addAddress(address, prefix) }
        plan.routes.forEach { (address, prefix) -> builder.addRoute(address, prefix) }
        plan.dns.forEach { builder.addDnsServer(it) }
        applyPerAppRules(builder, plan)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            plan.httpProxy?.let { (server, port, bypass) ->
                builder.setHttpProxy(ProxyInfo.buildDirectProxy(server, port, bypass))
            }
            // Android otherwise assumes a VPN is unmetered, so background sync treats it
            // as free WIFI even when it is riding on mobile data.
            builder.setMetered(plan.metered)
        }

        // Lets other apps escape the tunnel with their own bypass. Withholding it is
        // what strict_route means for a VpnService -- the core hands the option to
        // the platform rather than acting on it, because we are the ones who open
        // the TUN. Our own outbound sockets are unaffected: they escape through
        // protect(), which the dialer controller calls regardless.
        if (plan.bypassable) builder.allowBypass()
        return builder
    }

    /** Whether the device opened on [plan] is still there and up, as the system sees it. */
    private fun isUp(plan: TunPlan): Boolean = runCatching {
        val address = InetAddress.getByName(plan.addresses.first().first)
        JavaNetworkInterface.getByInetAddress(address)?.isUp == true
    }.getOrDefault(false)

    private fun uidOf(packageName: String): Int = runCatching {
        context.packageManager.getPackageUid(packageName, 0)
    }.getOrDefault(-1)

    /**
     * Per-app proxy. A package in the list that has since been uninstalled makes the
     * builder throw, which would take the whole tunnel down over a stale setting — so
     * each entry is applied independently and bad ones are dropped.
     */
    private fun applyPerAppRules(builder: VpnService.Builder, plan: TunPlan) {
        var appliedInclude = 0
        plan.include.forEach { (pkg, _) ->
            runCatching { builder.addAllowedApplication(pkg) }.onSuccess { appliedInclude++ }
        }
        // An include list that ended up empty would tunnel *everything*, silently
        // inverting the user's intent, so fall back to keeping ourselves in only.
        if (plan.include.isNotEmpty() && appliedInclude == 0) {
            runCatching { builder.addAllowedApplication(context.packageName) }
        }
        plan.exclude.forEach { (pkg, _) -> runCatching { builder.addDisallowedApplication(pkg) } }
    }

    /**
     * Leaves the device open with nothing behind it, for a tunnel about to be replaced.
     *
     * Traffic sent meanwhile waits or is lost. Closing it instead handed every app on
     * the phone back to the bare network for the seconds in between.
     */
    fun holdTun() {
        val held = tunDescriptor ?: return
        releaseHeldTun()
        heldDescriptor = held
        tunDescriptor = null
    }

    /** For after a start that opened no device of its own, when none is left to wait for. */
    fun releaseHeldTun() {
        runCatching { heldDescriptor?.close() }
        heldDescriptor = null
    }

    fun closeTun() {
        releaseHeldTun()
        runCatching { tunDescriptor?.close() }
        tunDescriptor = null
        openPlan = null
    }

    /** Has the next start open a device of its own, whatever state this one is in. */
    fun renewTun() {
        openPlan = null
    }

    // ---- socket protection -----------------------------------------------

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        // Without this the core's own sockets would be routed back into the tunnel.
        if (!service.protect(fd)) {
            throw IllegalStateException("protect($fd) failed; the VPN service is not running")
        }
    }

    // ---- connection ownership (per-app routing rules) ---------------------

    /**
     * The public API exists from Android 10; before that the core's own procfs scan is
     * asked instead. From 10 on SELinux blocks that scan, so the order cannot be swapped.
     * (sing-box 1.14.4 dropped `useProcFS()` and left this choice to the app.)
     */
    @SuppressLint("NewApi")
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        val uid = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Libbox.findConnectionOwner(ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort).userId
        } else {
            connectivity.getConnectionOwnerUid(
                ipProtocol,
                InetSocketAddress(sourceAddress, sourcePort),
                InetSocketAddress(destinationAddress, destinationPort),
            )
        }
        if (uid == android.os.Process.INVALID_UID) throw IllegalStateException("connection owner not found")

        val owner = ConnectionOwner()
        owner.userId = uid
        val packages = packagesByUid.computeIfAbsent(uid) {
            context.packageManager.getPackagesForUid(it)?.toList().orEmpty()
        }
        if (packages.isNotEmpty()) {
            owner.setAndroidPackageNames(packages.toBoxStringIterator())
            owner.processPath = packages.first()
        }
        return owner
    }

    // ---- default network monitoring --------------------------------------

    /** Starts watching for installs and removals, so [packagesByUid] cannot go stale. */
    private fun watchPackageChanges() {
        if (packageChangesRegistered) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addDataScheme("package")
        }
        // Best effort: a cache that cannot be invalidated is worse than no cache, so
        // failing to register means not caching at all.
        packageChangesRegistered = runCatching {
            ContextCompat.registerReceiver(
                context,
                packageChanges,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }.isSuccess
    }

    private fun stopWatchingPackageChanges() {
        if (!packageChangesRegistered) return
        packageChangesRegistered = false
        runCatching { context.unregisterReceiver(packageChanges) }
        packagesByUid.clear()
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        watchPackageChanges()
        // Subscribing to non-VPN networks only. registerDefaultNetworkCallback would
        // report our own tunnel as the default the moment it comes up, and reporting
        // the TUN as the default interface breaks every outbound dial (see NetworkProbe).
        updateListener = listener
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            private fun publish() {
                updateListener?.let { publishDefaultInterface(it) }
            }

            override fun onAvailable(network: Network) = publish()
            override fun onLost(network: Network) = publish()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = publish()
            override fun onLinkPropertiesChanged(network: Network, properties: android.net.LinkProperties) = publish()
        }
        networkCallback = callback
        connectivity.registerNetworkCallback(request, callback)
        // The callbacks are asynchronous; publish once up front so the core is not
        // left without a default interface for the first connections it makes.
        publishDefaultInterface(listener)
    }

    /**
     * The last interface reported to the core.
     *
     * The callbacks above fire on every capability and link-property change, which is
     * far more often than the link itself actually changes — so a genuine handover is
     * told apart by comparing what was last published.
     */
    private var lastInterface: Pair<String, Int>? = null

    /** Recomputes and reports the current underlying interface. */
    private fun publishDefaultInterface(listener: InterfaceUpdateListener) {
        val network = probe.bestNonVpnNetwork()
        if (network == null) {
            noteInterface("", -1)
            listener.updateDefaultInterface("", -1, false, false)
            return
        }
        val name = probe.interfaceNameOf(network)
        val index = name?.let { NetworkProbe.interfaceIndex(it) } ?: -1
        if (name == null || index < 0) {
            // An interface we cannot resolve an index for would never match sing-box's
            // list, so report "no default" instead of a value that silently breaks dialing.
            noteInterface("", -1)
            listener.updateDefaultInterface("", -1, false, false)
            return
        }
        val caps = probe.capabilitiesOf(network)
        val expensive = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
        val constrained = Build.VERSION.SDK_INT >= 36 &&
            caps?.hasCapability(NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED) == false
        noteInterface(name, index)
        listener.updateDefaultInterface(name, index, expensive, constrained)
    }

    /**
     * Records what was published, and tells the service when it actually changed.
     *
     * Connections opened over the old link do not survive the handover; they simply
     * stop carrying data until something times out. The service closes them, if the
     * user asked for that.
     */
    private fun noteInterface(name: String, index: Int) {
        val next = name to index
        val previous = lastInterface
        lastInterface = next
        if (previous != null && previous != next) service.onDefaultInterfaceChanged()
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        networkCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        networkCallback = null
        updateListener = null
        lastInterface = null
        // Paired with the registration in startDefaultInterfaceMonitor: a receiver
        // left behind after the tunnel stops is a leak the system will complain about.
        stopWatchingPackageChanges()
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        // Real transport types, so route rules keyed on WIFI/cellular work and the
        // core can tell a metered link from an unmetered one.
        val types = probe.interfaceTypes()
        val interfaces = JavaNetworkInterface.getNetworkInterfaces().toList().map { iface ->
            BoxNetworkInterface().apply {
                name = iface.name
                index = iface.index
                setMTU(runCatching { iface.mtu }.getOrDefault(0))
                addresses = iface.interfaceAddresses.map { it.toPrefixString() }.toBoxStringIterator()
                setDNSServer(emptyList<String>().toBoxStringIterator())
                flags = iface.toBoxFlags()
                type = types[iface.name] ?: Libbox.InterfaceTypeOther
            }
        }
        return interfaces.toBoxInterfaceIterator()
    }

    // ---- WIFI state (for `rule_set` / route rules keyed on SSID) ----------

    override fun readWIFIState(): WIFIState? {
        @Suppress("DEPRECATION")
        val wifi = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        @Suppress("DEPRECATION")
        val info = wifi.connectionInfo ?: return null
        // Without location permission Android returns this placeholder rather than failing.
        val ssid = info.ssid?.removeSurrounding("\"").orEmpty()
        if (ssid.isEmpty() || ssid == "<unknown ssid>") return null
        return WIFIState(ssid, info.bssid.orEmpty())
    }

    // ---- unused on Android -----------------------------------------------

    /**
     * Returning null here leaves sing-box on its Unix `local` resolver, which needs
     * `/etc/resolv.conf` and therefore resolves nothing on Android.
     */
    private val dnsTransport by lazy { LocalDnsTransport(context) }

    override fun localDNSTransport(): LocalDNSTransport = dnsTransport

    /** Apple-only concepts. */
    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false

    /** Android exposes no resolver-cache flush to unprivileged apps. */
    override fun clearDNSCache() = Unit

    override fun sendNotification(notification: Notification) {
        service.postCoreNotification(notification)
    }

    override fun cancelNotification(identifier: String, typeID: Int) {
        service.cancelCoreNotification(identifier)
    }

    // ---- added in sing-box 1.14, none of it used by this app -------------------
    // Answered the way libbox's own stub answers them: an optional feature declines
    // with an error the core reads as "not on this platform", the rest do nothing.

    /** For MAC-address rules; Android gives an unprivileged app no neighbour table. */
    override fun startNeighborMonitor(listener: NeighborUpdateListener?): Unit =
        throw UnsupportedOperationException("neighbour monitoring is not available")

    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) = Unit

    override fun registerMyInterface(name: String?) = Unit

    /** Tailscale SSH and SFTP: there is no shell to hand out here. */
    override fun usePlatformShell(): Boolean = false

    override fun checkPlatformShell() = Unit

    override fun openShellSession(
        user: PlatformUser?,
        command: String?,
        environ: StringIterator?,
        term: String?,
        rows: Int,
        cols: Int,
    ): ShellSession = throw UnsupportedOperationException("no platform shell")

    override fun lookupUser(username: String?): PlatformUser =
        throw UnsupportedOperationException("no platform users")

    override fun lookupSFTPServer(): String = throw UnsupportedOperationException("no SFTP server")

    override fun readSystemSSHHostKey(): String =
        throw UnsupportedOperationException("no SSH host key")

    override fun tailscaleHostname(): String = ""

    /** The L3 bridge outbound needs privileges an unrooted phone does not grant. */
    override fun usePlatformBridge(): Boolean = false

    override fun createBridge(options: BridgeOptions?): BridgeSession =
        throw UnsupportedOperationException("no platform bridge")

    private companion object {
        const val TUN_SESSION = "Trefoil"

        /** NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED, API 36. */
        const val NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED = 37

        fun InterfaceAddress.toPrefixString(): String {
            val addr = address.hostAddress?.substringBefore('%').orEmpty()
            return "$addr/$networkPrefixLength"
        }

        fun JavaNetworkInterface.toBoxFlags(): Int {
            var flags = 0
            runCatching {
                if (isUp) flags = flags or OsConstants.IFF_UP
                if (isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
                if (isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
                if (supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            }
            return flags
        }
    }
}
