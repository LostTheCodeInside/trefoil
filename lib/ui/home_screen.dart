import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/exit_ip.dart';
import '../core/profile/config_builder.dart';
import '../core/profile/outbound.dart';
import '../core/tunnel_status.dart';
import '../l10n/app_localizations.dart';
import 'l10n_ext.dart';
import '../main.dart';
import 'app_shell.dart';
import 'motion.dart';
import 'chips.dart';
import 'connect_button.dart';
import 'error_text.dart';
import 'speed_chart.dart';
import 'word_safe_segments.dart';

/// The connect screen: one control, and enough feedback to tell whether it worked.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onAddServer});

  /// Switches to the server list. Owned by the shell, which holds the tab index.
  final VoidCallback onAddServer;

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final status = controller.status;
    final selected = controller.selected;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ConnectButton(
                    status: status,
                    enabled: controller.canToggle,
                    stalled: controller.health == TunnelHealth.stalled,
                    // With no servers the button would otherwise be dead: tapping it
                    // does nothing and nothing says why. Better to let it explain
                    // itself and point at the fix.
                    onEmpty: controller.servers.isEmpty ? () => _promptForServer(context) : null,
                  ),
                  const SizedBox(height: 16),
                  _StatusLine(status: status),
                  const SizedBox(height: 4),
                  Text(
                    selected?.tag ??
                        (controller.servers.isEmpty ? l10n.noServersYet : l10n.noServerSelected),
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (selected != null) _Facts(server: selected),
                  _Health(connected: status.stage.isActive),
                  if (selected != null && !selected.isUsable) ...[
                    const SizedBox(height: 16),
                    _ErrorCard(
                      message: l10n.serverUnusable(describeProblem(l10n, selected.problem!)),
                    ),
                  ] else if (status.error != null && !status.stage.isActive) ...[
                    const SizedBox(height: 16),
                    _ErrorCard(message: status.error!),
                  ],
                  if (controller.mode != null) ...[
                    const SizedBox(height: 20),
                    _ModeSelector(mode: controller.mode!),
                  ],
                  const SizedBox(height: 24),
                  const SpeedChart(),
                  const SizedBox(height: 12),
                  const _TrafficPanel(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _promptForServer(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.noServersYet),
        behavior: SnackBarBehavior.floating,
        persist: false,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: l10n.actionAddServer, onPressed: onAddServer),
      ),
    );
  }
}

/// Quick routing mode. Switching is instant — every mode's rules are already in the
/// running config, so nothing needs to be rebuilt or reconnected.
class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return WordSafeSegments<String>(
      labels: {
        ConfigBuilder.modeRule: l10n.modeRule,
        ConfigBuilder.modeGlobal: l10n.modeGlobal,
        ConfigBuilder.modeDirect: l10n.modeDirect,
      },
      icons: const {
        ConfigBuilder.modeRule: Icons.alt_route,
        ConfigBuilder.modeGlobal: Icons.public,
        ConfigBuilder.modeDirect: Icons.arrow_forward,
      },
      selected: mode,
      onSelected: (value) {
        final controller = TunnelScope.read(context);
        if (controller.hapticFeedback) HapticFeedback.selectionClick();
        controller.setMode(value);
      },
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stage, and how long it has been that way.
///
/// The clock is driven from a timestamp the service stamps at the moment the tunnel
/// reaches STARTED, not from when this widget was built. The tunnel outlives the app:
/// Android recreates the Activity freely, and a duration measured from the UI's own
/// life would silently restart at zero every time that happened.
class _StatusLine extends StatefulWidget {
  const _StatusLine({required this.status});

  final TunnelStatus status;

  @override
  State<_StatusLine> createState() => _StatusLineState();
}

class _StatusLineState extends State<_StatusLine> {
  Timer? _ticker;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Nothing needs a second hand while the app is in the background; the value is
    // recomputed from the timestamp on resume, so it comes back correct rather than
    // resuming from wherever it was left.
    _lifecycle = AppLifecycleListener(onResume: _sync, onPause: _stop);
    _sync();
  }

  @override
  void didUpdateWidget(_StatusLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status.startedAt != widget.status.startedAt) _sync();
  }

  void _sync() {
    if (widget.status.startedAtTime == null) {
      _stop();
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      // Not while another tab is showing. [build] depends on TickerMode, and the
      // time is worked out from the start, so it is right the moment it is back.
      if (mounted && TickerMode.getValuesNotifier(context).value.enabled) setState(() {});
    });
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    TickerMode.valuesOf(context);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final started = widget.status.startedAtTime;
    final style = theme.textTheme.titleMedium;

    final label = widget.status.stage.label(l10n);
    if (started == null) return Text(label, style: style, textAlign: TextAlign.center);

    final uptime = formatUptime(DateTime.now().difference(started));
    final muted = style?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    // Otherwise every digit change nudges the whole line sideways, which is very
    // visible on something that updates once a second.
    final timeStyle = muted?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    const separator = '  ·  ';

    // One line when it fits, two when it does not: at the largest font sizes
    // "Connected · 1:02:05" is wider than a small phone. The separator only means
    // something between two things on the same line, so the stacked form drops it
    // rather than starting the second line with a stray dot.
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(
            children: [
              TextSpan(text: label, style: style),
              TextSpan(text: separator, style: muted),
              TextSpan(text: uptime, style: timeStyle),
            ],
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final fits = painter.width <= constraints.maxWidth;
        painter.dispose();

        final time = Text(uptime, style: timeStyle);
        if (!fits) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: style, textAlign: TextAlign.center),
              time,
            ],
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: style),
            Text(separator, style: muted),
            time,
          ],
        );
      },
    );
  }
}

/// `h:mm:ss` once past an hour, `mm:ss` before that.
///
/// Clamped at zero: the start time comes from the device's wall clock, so moving the
/// clock forward while connected can otherwise produce a negative uptime.
String formatUptime(Duration since) {
  final seconds = since.inSeconds < 0 ? 0 : since.inSeconds;
  final minutes = (seconds ~/ 60) % 60;
  final hours = seconds ~/ 3600;
  final rest = seconds % 60;
  final tail = '${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$tail' : tail;
}

/// Says so when the tunnel is up and carrying nothing.
///
/// Also the thing that asks. The core measures each server on its own schedule, but
/// only every few minutes and only when there is more than one server to compare —
/// which leaves the moment that matters most, the seconds right after connecting,
/// unmeasured. So this asks once shortly after the tunnel comes up and then keeps
/// asking, but only while someone is actually looking at this screen: a tunnel is
/// expected to run for hours in the background, and a warning nobody can see is not
/// worth a request a minute for all of them.
class _Health extends StatefulWidget {
  const _Health({required this.connected});

  final bool connected;

  @override
  State<_Health> createState() => _HealthState();
}

class _HealthState extends State<_Health> {
  /// Long enough for a working tunnel to have finished coming up, short enough that
  /// a broken one is called out while the user still has their thumb on the screen.
  static const _first = Duration(seconds: 6);
  static const _repeat = Duration(seconds: 45);

  Timer? _initial;
  Timer? _periodic;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _sync, onPause: _stop);
    _sync();
  }

  @override
  void didUpdateWidget(_Health oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connected != widget.connected) _sync();
  }

  void _sync() {
    if (!widget.connected) {
      _stop();
      return;
    }
    _initial ??= Timer(_first, () {
      _measure();
      _periodic ??= Timer.periodic(_repeat, (_) => _measure());
    });
  }

  void _measure() {
    if (!mounted) return;
    // Declines by itself when the tunnel is down or a test is already running.
    TunnelScope.read(context).testLatency();
  }

  void _stop() {
    _initial?.cancel();
    _initial = null;
    _periodic?.cancel();
    _periodic = null;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    if (controller.health != TunnelHealth.stalled) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final scheme = theme.colorScheme;
    // "Nothing is getting through" is the symptom. The core usually logged the cause
    // a second ago, and without it the warning leaves the reader nowhere to go.
    final reason = controller.lastCoreError;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.tunnelStalled,
                      style: theme.textTheme.titleSmall?.copyWith(color: scheme.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.tunnelStalledBody,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
                    ),
                    if (reason != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        reason,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer.withValues(alpha: 0.75),
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What is known about the server currently in use.
///
/// Three facts that each used to want a line of their own: which protocol carries the
/// traffic, how far away the server measured, and the address the outside world sees.
/// As pills they fit on one row and survive being glanced at, which is what actually
/// happens on this screen.
class _Facts extends StatelessWidget {
  const _Facts({required this.server});

  final Outbound server;

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.read(context);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      // Both sources are outside the controller's own notifications: latency arrives
      // with a group report and the exit address with a lookup, and neither should
      // rebuild the whole screen.
      child: VisibleListenableBuilder(
        listenable: controller.groupsChanged,
        builder: (context) => ValueListenableBuilder<ExitIp?>(
          valueListenable: controller.exitIp,
          builder: (context, exit, _) {
            final measured = controller.latency[server.tag];
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                InfoChip(icon: Icons.lan_outlined, label: server.displayType.toUpperCase()),
                if (measured != null && measured.isMeasured)
                  InfoChip(
                    icon: Icons.speed,
                    label: measured.isReachable
                        ? '${measured.delayMs} ms'
                        : AppLocalizations.of(context).latencyTimeout,
                    color: measured.isReachable
                        ? latencyColor(scheme, measured.delayMs)
                        : scheme.error,
                  ),
                if (exit != null) InfoChip(icon: Icons.public, label: exit.label),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The one part of the app that redraws every second.
///
/// It listens to the controller's telemetry notifier rather than to the controller
/// itself, so a counter ticking over repaints these two cards and nothing else.
///
/// The headline figures come from the core's aggregate counters, which carry no
/// breakdown by outbound at all. The proxy/direct split underneath is summed from
/// the per-connection byte deltas instead — the only place that attribution exists.
/// Both are read from the same traffic manager inside the core, so they track each
/// other closely; the split can run a little behind on a connection that closed
/// mid-second, which is why the headline is not derived from it.
class _TrafficPanel extends StatefulWidget {
  const _TrafficPanel();

  @override
  State<_TrafficPanel> createState() => _TrafficPanelState();
}

class _TrafficPanelState extends State<_TrafficPanel> {
  StreamSubscription<TrafficSplit>? _subscription;
  late final AppLifecycleListener _lifecycle;
  TrafficSplit? _split;

  @override
  void initState() {
    super.initState();
    // Subscribing makes the core report every connection's byte count, which is the
    // chattiest thing it publishes. It must not keep doing that for a screen the
    // user has switched away from -- the tunnel is expected to run for hours with
    // the app in the background.
    _lifecycle = AppLifecycleListener(onResume: _listen, onPause: _stop);
    _listen();
  }

  void _listen() {
    _subscription ??= TunnelScope.read(context).channel.trafficSplit.listen(
      (value) {
        if (mounted) setState(() => _split = value);
      },
      // No breakdown is an ordinary state -- the tunnel is down, or this is not
      // Android. The headline counters are unaffected.
      onError: (Object _) {
        if (mounted) setState(() => _split = null);
      },
    );
  }

  void _stop() {
    _subscription?.cancel();
    _subscription = null;
    if (mounted) setState(() => _split = null);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final telemetry = TunnelScope.read(context).telemetry;
    return VisibleListenableBuilder(
      listenable: telemetry,
      builder: (context) {
        final status = telemetry.value;
        // The counters are meaningless until the core reports a traffic source, so
        // the panel shows dashes rather than a convincing-looking zero.
        final available = status.trafficAvailable;
        // Shown only once a reading has actually arrived. Rendering zeros before
        // then would claim an attribution nothing has measured yet.
        final split = available ? _split : null;
        return Row(
          children: [
            Expanded(
              child: _Stat(
                icon: Icons.south_east,
                label: l10n.download,
                value: available ? '${formatBytes(status.downlink)}/s' : null,
                total: available ? formatBytes(status.downlinkTotal) : null,
                proxy: split == null ? null : '${formatBytes(split.proxyDown)}/s',
                direct: split == null ? null : '${formatBytes(split.directDown)}/s',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Stat(
                icon: Icons.north_east,
                label: l10n.upload,
                value: available ? '${formatBytes(status.uplink)}/s' : null,
                total: available ? formatBytes(status.uplinkTotal) : null,
                proxy: split == null ? null : '${formatBytes(split.proxyUp)}/s',
                direct: split == null ? null : '${formatBytes(split.directUp)}/s',
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.total,
    this.proxy,
    this.direct,
  });

  final IconData icon;
  final String label;

  /// The rate, or null before the core has reported one.
  final String? value;
  final String? total;

  /// Formatted rates for the two halves, or null when no breakdown is available.
  /// Always supplied together.
  final String? proxy;
  final String? direct;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        // One card is one fact, so a screen reader should say it in one breath:
        // "Download, 1.2 MB/s, proxy 1.0 MB/s, direct 200 KB/s, total 5 GB". Left
        // unmerged it becomes four separate stops, and the figures arrive with
        // nothing attached to say which is which.
        child: MergeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  // Flexible, because the card is half the screen minus its padding --
                  // about 110dp on a 360dp phone -- and the label has to survive both a
                  // longer translation than "Download" and a raised text scale. Neither
                  // is exotic, and the result of not fitting is a striped overflow bar.
                  Flexible(
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // The em dash is a placeholder, and read aloud it is either silence
              // or the words "em dash". Neither says that the figure is simply not in
              // yet, which is what someone hearing the card needs to know.
              Text(
                value ?? '—',
                style: theme.textTheme.titleMedium,
                semanticsLabel: value == null ? l10n.noReadingYet : null,
              ),
              if (proxy case final proxy?) ...[
                const SizedBox(height: 6),
                // Same two colours the connections list uses for the same two things,
                // so a rule sending a domain direct reads the same in both places.
                _Share(color: theme.colorScheme.primary, label: l10n.actionProxy, value: proxy),
                _Share(color: theme.colorScheme.tertiary, label: l10n.actionDirect, value: direct!),
              ],
              if (total case final value?)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    l10n.totalTraffic(value),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One side of the split. The dot is a shorthand, not the encoding — the label
/// carries the meaning, so this still reads without colour.
class _Share extends StatelessWidget {
  const _Share({required this.color, required this.label, required this.value});

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(label, style: muted, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 4),
          Text(value, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
