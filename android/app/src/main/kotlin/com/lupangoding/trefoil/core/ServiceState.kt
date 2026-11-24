package com.lupangoding.trefoil.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class TunnelStage { STOPPED, STARTING, STARTED, STOPPING }

data class TunnelState(
    val stage: TunnelStage = TunnelStage.STOPPED,
    val profileName: String = "",
    /** Last failure, kept after returning to STOPPED so the UI can explain why. */
    val error: String? = null,
    /**
     * Epoch millis the tunnel reached STARTED, or 0 while it is not up.
     *
     * Wall clock rather than elapsedRealtime because the value crosses the platform
     * channel and is subtracted from Dart's own clock on the other side. The cost is
     * that moving the device clock while connected skews the reading once; the
     * alternative is shipping two clocks and reconciling them every tick.
     */
    val startedAt: Long = 0L,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "stage" to stage.name.lowercase(),
        "profileName" to profileName,
        "error" to error,
        "startedAt" to startedAt,
    )
}

/**
 * Single source of truth for tunnel status, shared between the VpnService and the
 * Flutter bridge.
 *
 * This is deliberately a process-global rather than something bound to the Activity:
 * the service outlives the UI, and Android will happily recreate the Activity while
 * the tunnel keeps running. A StateFlow also replays the current value to a late
 * subscriber, so a UI that starts after the tunnel is already up still renders the
 * right thing instead of showing "disconnected" until the next change.
 */
object ServiceState {
    private val _state = MutableStateFlow(TunnelState())
    val state: StateFlow<TunnelState> = _state.asStateFlow()

    val current: TunnelState get() = _state.value

    fun update(
        stage: TunnelStage = current.stage,
        profileName: String = current.profileName,
        error: String? = current.error,
    ) {
        val previous = _state.value
        // Stamped here rather than by the caller, so every route that brings the
        // tunnel up -- the app, always-on, the quick-settings tile, a reconnect --
        // gets a start time without having to remember to pass one. Carried across
        // STARTED -> STARTED so an update that only changes the profile name does
        // not silently restart the clock.
        val startedAt = when {
            stage != TunnelStage.STARTED -> 0L
            previous.stage == TunnelStage.STARTED && previous.startedAt > 0L -> previous.startedAt
            else -> System.currentTimeMillis()
        }
        _state.value = TunnelState(stage, profileName, error, startedAt)
    }

    fun fail(message: String) {
        _state.value = TunnelState(TunnelStage.STOPPED, current.profileName, message)
    }
}
