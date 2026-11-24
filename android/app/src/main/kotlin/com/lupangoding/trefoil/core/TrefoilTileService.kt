package com.lupangoding.trefoil.core

import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi
import com.lupangoding.trefoil.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Connect and disconnect from the notification shade.
 *
 * The tile mirrors [ServiceState], so it stays correct when the tunnel is started or
 * stopped from anywhere else — including the notification's own action.
 */
@RequiresApi(Build.VERSION_CODES.N)
class TrefoilTileService : TileService() {

    private var scope: CoroutineScope? = null

    override fun onStartListening() {
        super.onStartListening()
        // A tile only receives updates while the shade is open, so the subscription
        // is scoped to that rather than to the service's whole lifetime.
        val newScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        scope = newScope
        newScope.launch {
            ServiceState.state.collectLatest { render(it) }
        }
    }

    override fun onStopListening() {
        scope?.cancel()
        scope = null
        super.onStopListening()
    }

    override fun onClick() {
        when (ServiceState.current.stage) {
            // Quick Settings opens over the lock screen, so without this anyone holding
            // the phone could switch the tunnel off and leave traffic going out by the
            // real address. Only this direction is guarded: turning protection on from
            // the lock screen costs nothing.
            TunnelStage.STARTED, TunnelStage.STARTING ->
                if (isLocked) unlockAndRun { disconnect() } else disconnect()
            TunnelStage.STOPPING -> Unit
            TunnelStage.STOPPED -> connect()
        }
    }

    private fun disconnect() {
        startService(
            Intent(this, TrefoilVpnService::class.java)
                .setAction(TrefoilVpnService.ACTION_STOP),
        )
    }

    /**
     * VPN consent needs an Activity, so when it has not been granted the tile opens
     * the app rather than failing with no explanation.
     */
    private fun connect() {
        if (AutoStart.startIfPossible(this)) return
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                android.app.PendingIntent.getActivity(
                    this,
                    0,
                    launch,
                    android.app.PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(launch)
        }
    }

    private fun render(state: TunnelState) {
        val tile = qsTile ?: return
        tile.state = when (state.stage) {
            TunnelStage.STARTED -> Tile.STATE_ACTIVE
            TunnelStage.STARTING, TunnelStage.STOPPING -> Tile.STATE_UNAVAILABLE
            TunnelStage.STOPPED -> Tile.STATE_INACTIVE
        }
        tile.label = "Trefoil"
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tunnel)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val text = AppLocale.context(this)
            tile.subtitle = when (state.stage) {
                TunnelStage.STARTED -> state.profileName.ifEmpty { text.getString(R.string.status_connected) }
                TunnelStage.STARTING -> text.getString(R.string.status_connecting)
                TunnelStage.STOPPING -> text.getString(R.string.status_disconnecting)
                TunnelStage.STOPPED -> text.getString(R.string.status_not_connected)
            }
        }
        tile.updateTile()
    }
}
