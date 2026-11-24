import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/tunnel_status.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';

/// Throughput over the last minute or so, drawn as a mirrored area.
///
/// Download runs above the centre line and upload below it, which makes position —
/// not hue — the thing that separates the two series. That matters here more than it
/// usually would: the palette follows the wallpaper on Android 12+, and the usage
/// screen already documents that its primary and tertiary can land close enough that
/// even full-colour vision struggles to tell a pair of bars apart. Two halves of one
/// hue cannot run into that.
///
/// The x axis is deliberately unlabelled. Samples arrive when the core reports, and
/// the reporting interval is a user setting between one and ten seconds, so the width
/// of this window is not a fixed number of seconds and claiming one would be a lie.
/// The shape and the peak are what the chart is for.
class SpeedChart extends StatefulWidget {
  const SpeedChart({super.key});

  /// Long enough to show a burst rise and fall, short enough that each sample keeps
  /// a pixel or two of its own on a phone.
  static const samples = 60;

  /// The smallest full-scale reading, so an idle tunnel draws a flat line instead of
  /// amplifying a few hundred bytes of keepalive into a mountain range.
  static const floor = 64 * 1024.0;

  @override
  State<SpeedChart> createState() => _SpeedChartState();
}

class _SpeedChartState extends State<SpeedChart> {
  final _down = <double>[];
  final _up = <double>[];
  late final ValueNotifier<TunnelStatus> _telemetry;

  @override
  void initState() {
    super.initState();
    _telemetry = TunnelScope.read(context).telemetry;
    _telemetry.addListener(_sample);
  }

  @override
  void dispose() {
    _telemetry.removeListener(_sample);
    super.dispose();
  }

  void _sample() {
    final status = _telemetry.value;
    // Counters mean nothing without a traffic source attached, and a shape left over
    // from the last session would otherwise sit here looking live.
    if (!status.stage.isActive || !status.trafficAvailable) {
      if (_down.isNotEmpty) setState(_clear);
      return;
    }
    _down.add(status.downlink.toDouble());
    _up.add(status.uplink.toDouble());
    if (_down.length > SpeedChart.samples) {
      _down.removeAt(0);
      _up.removeAt(0);
    }
    // Sampled on every tab, drawn only on this one: the history has to keep up while
    // another tab is showing, the picture does not. [build] depends on TickerMode,
    // so coming back into view redraws it with everything gathered meanwhile.
    if (TickerMode.getValuesNotifier(context).value.enabled) setState(() {});
  }

  void _clear() {
    _down.clear();
    _up.clear();
  }

  @override
  Widget build(BuildContext context) {
    TickerMode.valuesOf(context);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // Two points is the least that can draw a segment; below that there is nothing to
    // show and an empty card reads as broken rather than idle.
    final ready = _down.length >= 2;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !ready
          ? const SizedBox(width: double.infinity)
          : Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Both sides give way rather than overflow: at a large font
                    // size the two no longer fit on a phone's width.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.speedChartTitle,
                            style: theme.textTheme.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Named rather than left as a bare figure: it is the only
                        // scale the chart carries, and an unlabelled rate sitting
                        // above two live rates reads as a third live rate.
                        Flexible(
                          child: Text(
                            l10n.speedChartPeak('${formatBytes(_peak.round())}/s'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 96,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: _SpeedPainter(
                                  down: _down,
                                  up: _up,
                                  scale: math.max(_peak, SpeedChart.floor),
                                  capacity: SpeedChart.samples,
                                  color: theme.colorScheme.primary,
                                  baseline: theme.colorScheme.outlineVariant,
                                ),
                              ),
                            ),
                          ),
                          // The two halves name themselves, so the chart still reads
                          // when it is the first thing on screen rather than the last.
                          // Directional, so they sit at the reading edge in Arabic
                          // and Farsi. The series keeps its own left-to-right time
                          // axis either way — that convention does not mirror.
                          PositionedDirectional(
                            start: 0,
                            top: 0,
                            child: _Direction(icon: Icons.south_east, label: l10n.download),
                          ),
                          PositionedDirectional(
                            start: 0,
                            bottom: 0,
                            child: _Direction(icon: Icons.north_east, label: l10n.upload),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// Full scale for both halves, so a rate above the line and the same rate below it
  /// draw the same height.
  double get _peak {
    var peak = 0.0;
    for (final value in _down) {
      if (value > peak) peak = value;
    }
    for (final value in _up) {
      if (value > peak) peak = value;
    }
    return peak;
  }
}

class _Direction extends StatelessWidget {
  const _Direction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _SpeedPainter extends CustomPainter {
  const _SpeedPainter({
    required this.down,
    required this.up,
    required this.scale,
    required this.capacity,
    required this.color,
    required this.baseline,
  });

  final List<double> down;
  final List<double> up;

  /// The reading that reaches the top of a half. Never zero.
  final double scale;

  /// Samples the window holds when full. Drawing against this rather than against
  /// the current length means a filling chart grows in from the right instead of
  /// stretching every existing sample sideways on each tick.
  final int capacity;

  final Color color;
  final Color baseline;

  /// Kept clear at the top and bottom of the box for the two direction labels, so a
  /// burst at the oldest end of the window can never be drawn through one of them.
  static const _headroom = 15.0;

  @override
  void paint(Canvas canvas, Size size) {
    final middle = size.height / 2;
    canvas.drawLine(
      Offset(0, middle),
      Offset(size.width, middle),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );
    if (down.length < 2) return;

    final step = size.width / (capacity - 1);
    // Right-aligned: the newest sample sits at the right edge, where the eye looks
    // for "now", and the window fills leftward.
    final start = size.width - step * (down.length - 1);

    final span = math.max(middle - _headroom, 1.0);
    _series(canvas, down, start, step, middle, span, up: true, alpha: 1);
    _series(canvas, up, start, step, middle, span, up: false, alpha: 0.55);
  }

  void _series(
    Canvas canvas,
    List<double> values,
    double start,
    double step,
    double middle,
    double span, {
    required bool up,
    required double alpha,
  }) {
    final direction = up ? -1.0 : 1.0;
    final line = Path();
    for (var i = 0; i < values.length; i++) {
      final x = start + step * i;
      final y = middle + direction * (values[i] / scale).clamp(0.0, 1.0) * span;
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }

    final fill = Path.from(line)
      ..lineTo(start + step * (values.length - 1), middle)
      ..lineTo(start, middle)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.16 * alpha),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_SpeedPainter oldDelegate) =>
      // The lists are mutated in place, so identity says nothing: the parent rebuilds
      // this painter on every sample and the length or the tail has moved each time.
      true;
}
