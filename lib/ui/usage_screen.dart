import 'package:flutter/material.dart';

import '../core/profile/usage_history.dart';
import '../l10n/app_localizations.dart';
import 'app_shell.dart';

/// How much the tunnel has carried, by day.
///
/// One series, not two. Upload and download as separate coloured bars would need a
/// pair of hues that stay distinguishable, and the palette here follows the
/// wallpaper on Android 12+ — its primary and tertiary sit close enough that even
/// full-colour vision struggles to separate them. So the bars show the day's total,
/// which is the figure people actually want, and the split is given as text on the
/// day you select.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key});

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  late Future<List<DailyUsage>> _history = UsageHistoryStore.instance.load();

  /// Long enough to show a habit, short enough that each bar stays wide enough to
  /// hit: thirty bars on a 360dp screen leaves about 10dp each, which is not a
  /// target anyone can aim at.
  static const _days = 14;

  DailyUsage? _selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.usageTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.actionReload,
            onPressed: () => setState(() {
              _history = UsageHistoryStore.instance.load();
              _selected = null;
            }),
          ),
        ],
      ),
      body: FutureBuilder<List<DailyUsage>>(
        future: _history,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final history = snapshot.data!;
          if (history.isEmpty) {
            return _Empty(l10n);
          }
          final days = UsageHistoryStore.lastDays(history, _days);
          final month = UsageHistoryStore.totalInMonth(history, DateTime.now());

          return AdaptiveBody(
            child: ListView(
              padding: EdgeInsets.fromLTRB(20, 16, 20, bottomInset(context, extra: 24)),
              children: [
                _Hero(label: l10n.usageThisMonth, bytes: month),
                const SizedBox(height: 24),
                Text(l10n.usageLastDays(_days), style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 12),
                UsageChart(
                  days: days,
                  selected: _selected,
                  onSelect: (day) => setState(() => _selected = day),
                ),
                const SizedBox(height: 20),
                _Detail(day: _selected),
                const Divider(height: 40),
                Text(l10n.usageRecordedDays, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                // The same numbers as text: the chart alone would leave the figures
                // unreadable to anyone who cannot judge bar heights.
                for (final day in history.take(14)) _Row(day: day),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.label, required this.bytes});

  final String label;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        Text(
          formatBytes(bytes),
          style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Daily totals as bars.
///
/// Bars rather than a line: each day is a discrete quantity, not a reading along a
/// continuum, and a line between them would imply values in between.
///
/// Public so its geometry can be rendered and inspected in a test without a device.
class UsageChart extends StatelessWidget {
  const UsageChart({super.key, required this.days, required this.selected, required this.onSelect});

  final List<DailyUsage> days;
  final DailyUsage? selected;
  final ValueChanged<DailyUsage> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peak = days.fold<int>(0, (max, d) => d.total > max ? d.total : max);

    return SizedBox(
      height: 140,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final day in days)
            Expanded(
              child: GestureDetector(
                onTap: () => onSelect(day),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  // A surface gap between bars, so adjacent days never read as one.
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        // A day with no traffic still gets a sliver, so the axis
                        // reads as continuous rather than as missing days.
                        height: peak == 0 ? 2 : (2 + (day.total / peak) * 118),
                        decoration: BoxDecoration(
                          color: day == selected
                              ? scheme.primary
                              : scheme.primary.withValues(alpha: 0.55),
                          // Rounded at the data end only; the baseline stays square
                          // so bars sit on the axis rather than floating above it.
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The selected day, or a prompt when nothing is selected.
class _Detail extends StatelessWidget {
  const _Detail({required this.day});

  final DailyUsage? day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (day == null) {
      return Text(
        AppLocalizations.of(context).usageTapBar,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final l10n = AppLocalizations.of(context);
    final value = day!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_formatDate(value.date), style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '↑ ${formatBytes(value.upload)}   ↓ ${formatBytes(value.download)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    semanticsLabel:
                        '${l10n.upload} ${formatBytes(value.upload)}, '
                        '${l10n.download} ${formatBytes(value.download)}',
                  ),
                ],
              ),
            ),
            Text(formatBytes(value.total), style: theme.textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.day});

  final DailyUsage day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(_formatDate(day.date), style: theme.textTheme.bodyMedium)),
          Text(
            '↑ ${formatBytes(day.upload)}  ↓ ${formatBytes(day.download)}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            semanticsLabel:
                '${l10n.upload} ${formatBytes(day.upload)}, '
                '${l10n.download} ${formatBytes(day.download)}',
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 72,
            child: Text(
              formatBytes(day.total),
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.l10n);

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        l10n.usageEmpty,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _formatDate(DateTime date) => '${date.day} ${_months[date.month - 1]}';
