import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// One day's traffic.
class DailyUsage {
  const DailyUsage({required this.date, required this.upload, required this.download});

  final DateTime date;
  final int upload;
  final int download;

  int get total => upload + download;
}

/// Reads the daily totals the tunnel service records.
///
/// The writer is on the Android side, in UsageHistory.kt, because the tunnel is
/// expected to run with the app closed — which is most of the time — and a
/// Dart-side recorder would simply miss that traffic. This half only reads.
class UsageHistoryStore {
  UsageHistoryStore._();

  static final UsageHistoryStore instance = UsageHistoryStore._();

  /// `getApplicationSupportDirectory` is `context.getFilesDir()` on Android, which
  /// is where the service writes.
  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/usage-history.json');

  /// Newest first. Returns an empty list when nothing has been recorded yet, and
  /// also when the file is unreadable: a corrupt history is worth losing quietly,
  /// never worth an error in front of the user.
  Future<List<DailyUsage>> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const [];

      final days = <DailyUsage>[];
      for (final entry in decoded.entries) {
        final date = DateTime.tryParse(entry.key as String);
        final value = entry.value;
        if (date == null || value is! Map) continue;
        days.add(
          DailyUsage(
            date: date,
            upload: (value['up'] as num?)?.toInt() ?? 0,
            download: (value['down'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      days.sort((a, b) => b.date.compareTo(a.date));
      return days;
    } catch (_) {
      return const [];
    }
  }

  /// Fills gaps so a chart shows quiet days as empty rather than skipping them,
  /// which would silently compress the time axis.
  static List<DailyUsage> lastDays(List<DailyUsage> history, int count) {
    final byDate = {for (final day in history) _key(day.date): day};
    final today = DateTime.now();
    return [
      for (var i = count - 1; i >= 0; i--)
        () {
          final date = DateTime(today.year, today.month, today.day - i);
          return byDate[_key(date)] ?? DailyUsage(date: date, upload: 0, download: 0);
        }(),
    ];
  }

  static int totalInMonth(List<DailyUsage> history, DateTime month) => history
      .where((d) => d.date.year == month.year && d.date.month == month.month)
      .fold(0, (sum, d) => sum + d.total);

  static String _key(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
