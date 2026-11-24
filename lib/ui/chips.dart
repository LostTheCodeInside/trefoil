import 'package:flutter/material.dart';

import '../core/tunnel_status.dart';
import '../l10n/app_localizations.dart';

/// Where a round trip stops being fine and starts being worth noticing.
///
/// Three bands rather than a gradient: the number is already on screen for anyone who
/// wants the detail, and colour here is only meant to answer "good, or not".
Color latencyColor(ColorScheme scheme, int ms) => ms < 300
    ? scheme.primary
    : ms < 800
    ? scheme.tertiary
    : scheme.error;

/// Latency badge. Distinguishes "not measured" from "measured and unreachable",
/// which look the same in the core's report: both carry a delay of zero.
class LatencyChip extends StatelessWidget {
  const LatencyChip({super.key, required this.item});

  final OutboundItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!item.isMeasured) return const SizedBox.shrink();
    if (!item.isReachable) {
      return Text(
        AppLocalizations.of(context).latencyTimeout,
        style: TextStyle(fontSize: 12, color: scheme.error),
      );
    }
    return Text(
      '${item.delayMs} ms',
      style: TextStyle(
        fontSize: 12,
        color: latencyColor(scheme, item.delayMs),
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// A small pill carrying one fact.
///
/// The connect screen has three of them — which protocol, how far away, where the
/// traffic comes out — and they were three separate lines of prose before. A row of
/// pills fits them in the space of one and reads at a glance, which is all anyone
/// does on this screen.
class InfoChip extends StatelessWidget {
  const InfoChip({super.key, required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;

  /// Tints the icon and the text. The pill itself stays neutral, so a row of them
  /// does not turn into a traffic light.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: tint),
          const SizedBox(width: 5),
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: tint)),
        ],
      ),
    );
  }
}
