package com.lupangoding.trefoil.core

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.lupangoding.trefoil.R

/**
 * Home screen widget: current state, and one tap to change it.
 *
 * A widget has no process of its own — the system asks for a [RemoteViews] and draws
 * it. So the widget cannot observe [ServiceState]; instead [refresh] is called
 * whenever the tunnel's state changes, which is what keeps it honest when the tunnel
 * is started or stopped from somewhere else.
 */
class TrefoilWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = render(context)
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    companion object {
        /** Redraws every placed widget. Safe to call when none exist. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = runCatching {
                manager.getAppWidgetIds(ComponentName(context, TrefoilWidgetProvider::class.java))
            }.getOrNull() ?: return
            if (ids.isEmpty()) return
            val views = render(context)
            ids.forEach { runCatching { manager.updateAppWidget(it, views) } }
        }

        private fun render(context: Context): RemoteViews {
            val state = ServiceState.current
            val text = AppLocale.context(context)
            return RemoteViews(context.packageName, R.layout.widget_tunnel).apply {
                setTextViewText(
                    R.id.widget_status,
                    text.getString(
                        when (state.stage) {
                            TunnelStage.STARTED -> R.string.status_connected
                            TunnelStage.STARTING -> R.string.status_connecting
                            TunnelStage.STOPPING -> R.string.status_disconnecting
                            TunnelStage.STOPPED -> R.string.widget_tap_to_connect
                        },
                    ),
                )
                setTextViewText(
                    R.id.widget_profile,
                    state.error ?: state.profileName.ifEmpty { "Trefoil" },
                )
                setOnClickPendingIntent(R.id.widget_root, WidgetToggleReceiver.pendingIntent(context))
            }
        }
    }
}

/**
 * What a tap on the widget does.
 *
 * Its own receiver, and not exported, because the widget provider has to be: the
 * system delivers widget updates from outside the app. While the toggle lived on the
 * provider, any installed app could send it — no permission needed — and turn the
 * tunnel off without the user seeing a thing, which on a VPN means traffic quietly
 * leaving by the real address. A PendingIntent runs as this app, so the widget can
 * still reach a receiver nothing else can.
 */
class WidgetToggleReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (ServiceState.current.stage) {
            TunnelStage.STARTED, TunnelStage.STARTING ->
                context.startService(
                    Intent(context, TrefoilVpnService::class.java)
                        .setAction(TrefoilVpnService.ACTION_STOP),
                )
            // Mid-transition taps are ignored rather than queued: the state is about
            // to change anyway, and acting now would fight it.
            TunnelStage.STOPPING -> Unit
            TunnelStage.STOPPED -> connect(context)
        }
        TrefoilWidgetProvider.refresh(context)
    }

    /**
     * VPN consent needs an Activity, so without it the widget opens the app instead
     * of failing where the user cannot see why.
     */
    private fun connect(context: Context) {
        if (AutoStart.startIfPossible(context)) return
        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ?: return
        runCatching { context.startActivity(launch) }
    }

    companion object {
        fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, WidgetToggleReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
