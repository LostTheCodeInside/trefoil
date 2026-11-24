package com.lupangoding.trefoil.core

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.security.MessageDigest

/**
 * Hands a downloaded update to Android's package installer, once it has been shown to
 * be what the release manifest described: the same bytes, this app, a newer build,
 * and signed by the key the installed app carries.
 *
 * Android refuses an update signed by another key on its own. Checking first turns
 * that refusal into a reason the screen can give, and keeps anything that is not this
 * app's update from reaching the installer at all.
 */
object UpdateInstaller {

    /** Install results go here while the UI is up; set and cleared by the bridge. */
    @Volatile
    var listener: ((status: String, detail: String) -> Unit)? = null

    /** The only place an update is accepted from: this app's own cache. */
    fun updatesDir(context: Context) = File(context.cacheDir, "updates")

    fun canInstall(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()

    /** Null when [apk] may be installed, otherwise why not. */
    fun verify(context: Context, apk: File, sha256: String, versionCode: Long): String? {
        if (!isInside(apk, updatesDir(context)) || !apk.isFile) return "bad_path"
        if (!sha256(apk).equals(sha256, ignoreCase = true)) return "hash_mismatch"
        val pm = context.packageManager
        val archive = archiveInfo(pm, apk) ?: return "unreadable"
        if (archive.packageName != context.packageName) return "wrong_package"
        if (versionCodeOf(archive) != versionCode) return "manifest_mismatch"
        val installed = installedInfo(pm, context.packageName)
        if (versionCodeOf(archive) <= versionCodeOf(installed)) return "not_newer"
        if (!sameSigners(signersOf(archive), signersOf(installed))) return "signature_mismatch"
        return null
    }

    /**
     * Writes [apk] into an installer session and commits it. Android then asks the
     * user to confirm; the answer arrives at [UpdateStatusReceiver].
     */
    fun commit(context: Context, apk: File) {
        val installer = context.packageManager.packageInstaller
        // A session left by an attempt that died halfway would only ever be in the way.
        installer.mySessions.forEach { runCatching { installer.abandonSession(it.sessionId) } }

        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(context.packageName)
        params.setSize(apk.length())
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("update.apk", 0, apk.length()).use { output ->
                        input.copyTo(output, 1 shl 16)
                        session.fsync(output)
                    }
                }
                // Mutable because the installer fills in the result; explicit, so only
                // the receiver below can be on the other end of it.
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                val callback = Intent(context, UpdateStatusReceiver::class.java)
                session.commit(PendingIntent.getBroadcast(context, sessionId, callback, flags).intentSender)
            }
        } catch (t: Throwable) {
            runCatching { installer.abandonSession(sessionId) }
            throw t
        }
    }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().toHex()
    }

    /** Whether [file] is inside [dir] once both are resolved: no `..`, no symlink out. */
    fun isInside(file: File, dir: File): Boolean =
        file.canonicalPath.startsWith(dir.canonicalPath + File.separator)

    /**
     * Unknown on either side means Android could not say, which it does for some
     * archives on older versions. The installer still compares the keys itself, so
     * that case is left to it rather than refused here.
     */
    fun sameSigners(a: Set<String>?, b: Set<String>?): Boolean =
        a.isNullOrEmpty() || b.isNullOrEmpty() || a == b

    fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }

    private fun archiveInfo(pm: PackageManager, apk: File): PackageInfo? =
        @Suppress("DEPRECATION")
        pm.getPackageArchiveInfo(apk.path, signingFlag())

    private fun installedInfo(pm: PackageManager, packageName: String): PackageInfo =
        @Suppress("DEPRECATION")
        pm.getPackageInfo(packageName, signingFlag())

    @Suppress("DEPRECATION")
    private fun signingFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    private fun signersOf(info: PackageInfo): Set<String>? {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            info.signatures
        }
        val sha = MessageDigest.getInstance("SHA-256")
        return signatures?.map { sha.digest(it.toByteArray()).toHex() }?.toSet()
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}

/**
 * Where the installer reports. Not exported: only the system, holding this app's
 * pending intent, can reach it, so the confirmation intent it carries can be trusted
 * enough to start.
 */
class UpdateStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> confirm(context, intent)
            PackageInstaller.STATUS_SUCCESS -> report("installed", "")
            PackageInstaller.STATUS_FAILURE_ABORTED -> report("cancelled", "")
            else -> report(
                "failed",
                intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "status $status",
            )
        }
    }

    private fun confirm(context: Context, intent: Intent) {
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val ours = context.packageManager.packageInstaller.mySessions.any { it.sessionId == sessionId }
        // The typed lookup only from 14: on 13 it can come back null for an extra that is there.
        val confirmation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }
        if (!ours || confirmation == null) {
            report("failed", "unexpected confirmation request")
            return
        }
        runCatching { context.startActivity(confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .onSuccess { report("waiting", "") }
            .onFailure { report("failed", it.message ?: it.toString()) }
    }

    private fun report(status: String, detail: String) {
        UpdateInstaller.listener?.invoke(status, detail)
    }
}
