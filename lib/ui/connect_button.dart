import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/tunnel_status.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';

/// The one control on the connect screen.
///
/// Everything here answers "is it on?" from across the room: the fill colour, the
/// ring that sweeps while the tunnel is coming up, and the halo that keeps moving
/// once it is up. The motion is the part a still frame cannot fake — a static
/// "Connected" label reads the same whether the tunnel is alive or wedged, and this
/// screen spends most of its life being glanced at rather than read.
class ConnectButton extends StatefulWidget {
  const ConnectButton({
    super.key,
    required this.status,
    required this.enabled,
    this.stalled = false,
    this.onEmpty,
  });

  final TunnelStatus status;
  final bool enabled;

  /// The tunnel is up but nothing is reaching the other end.
  ///
  /// Drawn as an error rather than as a connection, and the halo stops: rings
  /// travelling outward say "alive", which is exactly the wrong thing to say here.
  final bool stalled;

  /// Set only when there is nothing to connect to; explains rather than acts.
  final VoidCallback? onEmpty;

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton> with SingleTickerProviderStateMixin {
  /// The disc itself. The box around it is wider so the halo has somewhere to go —
  /// far enough that a ring reads as travelling rather than as a thick edge, and
  /// still inside the 24dp margins on a 320dp screen.
  static const _disc = 176.0;
  static const _box = 256.0;

  late final AnimationController _halo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  bool _pressed = false;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncHalo();
  }

  @override
  void didUpdateWidget(ConnectButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status.stage != widget.status.stage || oldWidget.stalled != widget.stalled) {
      _syncHalo();
    }
  }

  /// The halo repeats forever, so it must be running only when it is both wanted and
  /// visible. A controller left repeating holds the vsync callback open and keeps the
  /// engine producing frames for a screen showing nothing that moves.
  void _syncHalo() {
    final wanted = widget.status.stage.isActive && !widget.stalled && !_reduceMotion;
    if (wanted && !_halo.isAnimating) {
      _halo.repeat();
    } else if (!wanted && _halo.isAnimating) {
      _halo
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final active = widget.status.stage.isActive;
    final busy = widget.status.stage.isBusy;
    final stalled = active && widget.stalled;
    final fill = stalled
        ? scheme.error
        : active
        ? scheme.primary
        : scheme.surfaceContainerHighest;

    // Taps while the tunnel is starting cancel it; while it is stopping they do nothing,
    // which is the controller's to decide.
    final onTap = widget.enabled
        ? () {
            final controller = TunnelScope.read(context);
            if (controller.hapticFeedback) HapticFeedback.mediumImpact();
            controller.toggle();
          }
        : widget.onEmpty;

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: active
          ? l10n.actionDisconnect
          : widget.status.stage == TunnelStage.starting
          ? l10n.actionCancel
          : l10n.actionConnect,
      child: SizedBox(
        width: _box,
        height: _box,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Its own layer: a ring repainting at 60fps should not drag the disc, the
            // icon and the ink ripple into the same repaint.
            if (active && !stalled && !_reduceMotion)
              Positioned.fill(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _halo,
                    builder: (context, _) => CustomPaint(
                      painter: _HaloPainter(
                        progress: _halo.value,
                        color: scheme.primary,
                        innerRadius: _disc / 2,
                      ),
                    ),
                  ),
                ),
              ),
            // Built only while the stage is in flight rather than faded out in place:
            // an indeterminate indicator keeps animating at zero opacity, which is a
            // permanently spinning frame budget for something nobody can see.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: busy
                  ? SizedBox(
                      key: const ValueKey(true),
                      width: _disc + 16,
                      height: _disc + 16,
                      child: CircularProgressIndicator(strokeWidth: 3, color: scheme.primary),
                    )
                  : const SizedBox.shrink(),
            ),
            AnimatedScale(
              scale: _pressed ? 0.94 : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                width: _disc,
                height: _disc,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fill,
                  // Lerps to and from nothing on its own, and costs no blur pass once
                  // it has settled back to an empty list.
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: fill.withValues(alpha: 0.32),
                            blurRadius: 36,
                            spreadRadius: 2,
                          ),
                        ]
                      : const [],
                ),
                child: Material(
                  type: MaterialType.transparency,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onTap,
                    onTapDown: onTap == null ? null : (_) => setState(() => _pressed = true),
                    onTapUp: onTap == null ? null : (_) => setState(() => _pressed = false),
                    onTapCancel: onTap == null ? null : () => setState(() => _pressed = false),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(scale: animation, child: child),
                        ),
                        child: Icon(
                          stalled
                              ? Icons.priority_high
                              : active
                              ? Icons.power_settings_new
                              : Icons.power_settings_new_outlined,
                          key: ValueKey((active, stalled)),
                          size: 72,
                          color: stalled
                              ? scheme.onError
                              : active
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rings travelling outward from the disc, evenly spaced in phase.
///
/// Three is enough to read as continuous and few enough to stay a rounding error in
/// the frame budget: three stroked circles, no blur, no layer.
class _HaloPainter extends CustomPainter {
  const _HaloPainter({required this.progress, required this.color, required this.innerRadius});

  /// Repeating 0..1. Each ring runs the same trip offset by a third of it.
  final double progress;
  final Color color;
  final double innerRadius;

  static const _rings = 3;
  static const _fadeIn = 0.15;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    if (outer <= innerRadius) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (var i = 0; i < _rings; i++) {
      final phase = (progress + i / _rings) % 1.0;
      // Fades in over the first stretch as well as out over the whole trip, so a ring
      // grows out of the disc rather than appearing beside it at full strength.
      final opacity = (1 - phase) * (phase < _fadeIn ? phase / _fadeIn : 1.0) * 0.4;
      if (opacity <= 0.01) continue;
      canvas.drawCircle(
        center,
        innerRadius + (outer - innerRadius) * phase,
        paint..color = color.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.innerRadius != innerRadius;
}
