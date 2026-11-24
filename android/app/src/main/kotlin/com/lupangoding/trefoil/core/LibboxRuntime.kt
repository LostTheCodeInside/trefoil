package com.lupangoding.trefoil.core

import android.content.Context
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libruntime.Libruntime
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-global libbox initialisation.
 *
 * `Libbox.setup` writes package-level state in Go and must run exactly once before
 * any other libbox call — including the static helpers like `checkConfig` that the
 * UI uses while the tunnel is down. Both the service and the Flutter bridge route
 * through here so neither has to know whether the other got there first.
 */
object LibboxRuntime {
    private val ready = AtomicBoolean(false)

    fun ensureSetup(context: Context) {
        if (!ready.compareAndSet(false, true)) return
        val app = context.applicationContext
        val base = app.filesDir.also { it.mkdirs() }
        runCatching {
            Libbox.setup(
                SetupOptions().apply {
                    basePath = base.absolutePath
                    workingPath = File(base, "work").also { it.mkdirs() }.absolutePath
                    tempPath = app.cacheDir.also { it.mkdirs() }.absolutePath
                    // Works around a Go runtime stack probe that misfires on Android.
                    fixAndroidStack = true
                    // Zero is a socket file in basePath rather than a port. A port on
                    // loopback is open to every app on the device; this is open to
                    // ours, and the kernel is what says so.
                    commandServerListenPort = 0
                    commandServerSecret = CommandSecret.get(app)
                    // Bounded so a chatty core cannot grow the log buffer without limit.
                    logMaxLines = 300L
                    debug = AppPrefs.debug(app)
                },
            )
            // Static and callable at any time, unlike the options above.
            Libruntime.setLowMemory(AppPrefs.memoryLimit(app))
        }.onFailure {
            // Let a later call retry rather than leaving the process permanently unusable.
            ready.set(false)
            throw it
        }
    }

    fun configFile(context: Context) = File(context.applicationContext.filesDir, "current-config.json")

    /**
     * Xray's config, written only when the selected server needs the second core.
     * Absence of this file is what tells the service to run sing-box alone.
     */
    fun xrayConfigFile(context: Context) = File(context.applicationContext.filesDir, "current-xray.json")

    /**
     * The AmneziaWG config, written only when the selected server needs the third
     * core. Its absence is what tells the service not to raise that tunnel.
     *
     * A WireGuard config file rather than JSON, because that is what the library
     * takes and what the user was given — translating it twice would be one more
     * place for a parameter to be dropped.
     */
    fun amneziaConfigFile(context: Context) = File(context.applicationContext.filesDir, "current-amnezia.conf")

    /**
     * Config is written temp-then-rename so a crash mid-write can never leave a
     * truncated file that would fail to parse on the next start.
     */
    fun writeConfig(context: Context, content: String) = AtomicFiles.write(configFile(context), content)

    /** Passing null removes the file, so a previous Xray profile cannot linger. */
    fun writeXrayConfig(context: Context, content: String?) = writeOrRemove(xrayConfigFile(context), content)

    /** Same, for the AmneziaWG tunnel. */
    fun writeAmneziaConfig(context: Context, content: String?) =
        writeOrRemove(amneziaConfigFile(context), content)

    /**
     * Where the AmneziaWG core serves SOCKS and the credentials it demands: the same
     * set the sing-box config dials it with. Its own file because the tunnel's config
     * is a WireGuard file, which has nowhere to put them.
     */
    private fun amneziaSocksFile(context: Context) =
        File(context.applicationContext.filesDir, "current-amnezia-socks.json")

    fun writeAmneziaSocks(context: Context, socks: AmneziaRuntime.Socks?) =
        writeOrRemove(amneziaSocksFile(context), socks?.toJson())

    /**
     * Absent for a config written before the hand-off was authenticated. That config's
     * sing-box side dials the old fixed port with no credentials, so that is what the
     * core must serve until the next connect rewrites both.
     */
    fun readAmneziaSocks(context: Context): AmneziaRuntime.Socks =
        amneziaSocksFile(context).takeIf { it.isFile }
            ?.let { runCatching { it.readText() }.getOrNull() }
            ?.let(AmneziaRuntime.Socks::parse)
            ?: AmneziaRuntime.Socks.LEGACY

    private fun writeOrRemove(target: File, content: String?) {
        if (content == null) {
            target.delete()
            return
        }
        AtomicFiles.write(target, content)
    }
}
