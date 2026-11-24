import 'package:flutter/material.dart';

import '../core/speed_test.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';

/// Measures the connection as it stands, through whichever server is in use.
///
/// Three figures taken in the order they matter: how far away the far end is, then
/// what comes back, then what goes out. Each appears as it is measured rather than
/// all at the end — a throughput test takes long enough that a blank screen reads as
/// a hang.
Future<void> showSpeedTest(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => const _SpeedTestSheet(),
);

class _SpeedTestSheet extends StatefulWidget {
  const _SpeedTestSheet();

  @override
  State<_SpeedTestSheet> createState() => _SpeedTestSheetState();
}

class _SpeedTestSheetState extends State<_SpeedTestSheet> {
  static const _test = SpeedTest();

  bool _running = false;
  bool _done = false;
  Duration? _latency;
  double? _download;
  double? _upload;

  /// Which figure is being taken, so exactly one row shows a spinner.
  int _step = 0;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _done = false;
      _latency = null;
      _download = null;
      _upload = null;
      _step = 1;
    });

    final latency = await _test.latency();
    if (!mounted) return;
    setState(() {
      _latency = latency;
      _step = 2;
    });

    final download = await _test.download();
    if (!mounted) return;
    setState(() {
      _download = download;
      _step = 3;
    });

    final upload = await _test.upload();
    if (!mounted) return;
    setState(() {
      _upload = upload;
      _step = 0;
      _running = false;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final controller = TunnelScope.of(context);
    final active = controller.activeTag ?? controller.selected?.tag;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, sheetInset(context, extra: 20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.speed, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.speedTest, style: theme.textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.speedTestBody,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (active != null) ...[
            const SizedBox(height: 6),
            Text(active, style: theme.textTheme.labelMedium),
          ],
          // Said before the numbers, not after: a figure read first and qualified
          // second is a figure already believed.
          if (!controller.appIsTunnelled) ...[
            const SizedBox(height: 12),
            _Warning(text: l10n.speedTestOutsideTunnel),
          ],
          const SizedBox(height: 16),
          _Row(
            icon: Icons.timer_outlined,
            label: l10n.speedTestLatency,
            busy: _step == 1,
            value: _latency == null ? null : '${_latency!.inMilliseconds} ms',
            missing: _done && _latency == null,
            failed: l10n.speedTestFailed,
          ),
          _Row(
            icon: Icons.south_east,
            label: l10n.download,
            busy: _step == 2,
            value: _download == null ? null : formatBitrate(_download!),
            missing: (_done || _step > 2) && _download == null,
            failed: l10n.speedTestFailed,
          ),
          _Row(
            icon: Icons.north_east,
            label: l10n.upload,
            busy: _step == 3,
            value: _upload == null ? null : formatBitrate(_upload!),
            missing: _done && _upload == null,
            failed: l10n.speedTestFailed,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.speedTestStart),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.busy,
    required this.value,
    required this.missing,
    required this.failed,
  });

  final IconData icon;
  final String label;
  final bool busy;
  final String? value;

  /// Measured, and there was nothing to report. Distinct from "not yet".
  final bool missing;
  final String failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          if (busy)
            const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
          else if (value case final value?)
            Text(value, style: theme.textTheme.titleMedium)
          else if (missing)
            Text(failed, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error))
          else
            Text(
              '—',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              semanticsLabel: AppLocalizations.of(context).noReadingYet,
            ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }
}
