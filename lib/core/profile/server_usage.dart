import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// What one server has carried, for as long as it has been in the list.
class ServerUsage {
  const ServerUsage({required this.upload, required this.download});

  final int upload;
  final int download;

  int get total => upload + download;

  static const none = ServerUsage(upload: 0, download: 0);
}

/// Reads the per-server totals the tunnel service records.
///
/// The writer is on the Android side, in ServerUsage.kt, for the same reason the
/// daily history's is: the tunnel is expected to run with the app closed, which is
/// most of the time, and a Dart-side recorder would miss exactly the traffic worth
/// counting. This half only reads.
class ServerUsageStore {
  ServerUsageStore._();

  static final ServerUsageStore instance = ServerUsageStore._();

  /// `getApplicationSupportDirectory` is `context.getFilesDir()` on Android, which
  /// is where the service writes.
  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/server-usage.json');

  /// Keyed by server tag. Empty when nothing has been recorded yet, and also when
  /// the file is unreadable: a corrupt total is worth losing quietly, never worth an
  /// error in front of the user.
  Future<Map<String, ServerUsage>> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const {};
      return parse(jsonDecode(await file.readAsString()));
    } catch (_) {
      return const {};
    }
  }

  /// Separate from reading the file so it can be tested without one.
  ///
  /// Tolerant on purpose: this is written by another process, and a single entry
  /// that is not what we expect must not cost the rest of them.
  static Map<String, ServerUsage> parse(Object? decoded) {
    if (decoded is! Map) return const {};
    final out = <String, ServerUsage>{};
    for (final entry in decoded.entries) {
      final tag = entry.key;
      final value = entry.value;
      if (tag is! String || tag.isEmpty || value is! Map) continue;
      final usage = ServerUsage(
        upload: (value['up'] as num?)?.toInt() ?? 0,
        download: (value['down'] as num?)?.toInt() ?? 0,
      );
      if (usage.total > 0) out[tag] = usage;
    }
    return out;
  }
}
