import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'routing.dart';

/// Downloads and caches the binary rule sets the presets rely on.
///
/// sing-box can fetch remote rule sets itself, but a failed *initial* download is
/// fatal: it aborts service start, so an unreachable GitHub would mean the tunnel
/// refuses to come up at all. Fetching them here instead turns that into an ordinary
/// error message, and lets the config reference them as local files that always exist
/// by the time the core reads them.
class RuleSetStore {
  /// [directory] overrides where the `.srs` files live; the app leaves it unset.
  /// Tests point it at a temp directory.
  RuleSetStore({Directory? directory}) : _override = directory;

  static final RuleSetStore instance = RuleSetStore();

  final Directory? _override;

  /// Rule sets change slowly; refetching more often would waste the user's data for
  /// no benefit. A stale set is still used, so an offline device keeps working.
  static const refreshAfter = Duration(days: 7);
  static const _timeout = Duration(seconds: 30);

  /// A compiled rule set is at most a few megabytes. The cap is what stops a wrong
  /// or hostile URL from filling the device's storage.
  static const maxBytes = 32 * 1024 * 1024;

  Directory? _dir;

  Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = _override ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/rule-sets');
    await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> fileFor(RuleSetPreset preset) async =>
      File('${(await _directory()).path}/${preset.id}.srs');

  Future<DateTime?> lastUpdated(RuleSetPreset preset) async {
    final file = await fileFor(preset);
    return file.existsSync() ? file.lastModifiedSync() : null;
  }

  /// Ensures every given preset has a usable local file.
  ///
  /// Returns the presets that could not be made available. Callers decide what to do
  /// with those; the tunnel must not reference a rule set whose file is missing,
  /// because sing-box treats that as a fatal config error.
  ///
  /// [within] caps how long the caller is prepared to wait. Downloads that have not
  /// finished by then keep going and land for next time — they are just no longer
  /// worth blocking on. Connecting passes this; a first connect otherwise fetched
  /// every list one after another, each with its own 30-second timeout, leaving the
  /// connect button looking dead for minutes on a slow network.
  Future<List<RuleSetPreset>> ensureAvailable(
    List<RuleSetPreset> presets, {
    bool force = false,
    Duration? within,
    String source = RuleSetSource.official,
    String base = '',
    bool allowInsecure = false,
  }) async {
    final pending = <Future<void>>[];
    for (final preset in presets) {
      final file = await fileFor(preset);
      final age = file.existsSync() ? DateTime.now().difference(file.lastModifiedSync()) : null;
      final fresh = age != null && age < refreshAfter;
      if (fresh && !force) continue;
      // Concurrently: these are independent files on the same host.
      // A failure is not fatal here -- an existing copy, however old, beats having
      // no rule set at all, and what is actually on disk is checked below.
      pending.add(
        _download(
          preset.urlFor(source, base),
          file,
          allowInsecure: allowInsecure,
        ).catchError((Object _) {}),
      );
    }

    if (pending.isNotEmpty) {
      final all = Future.wait(pending);
      if (within == null) {
        await all;
      } else {
        await all.timeout(within, onTimeout: () => const <void>[]);
      }
    }

    // Judged by what is on disk rather than by which downloads succeeded, so a set
    // that was already there counts as available even if its refresh failed.
    final failed = <RuleSetPreset>[];
    for (final preset in presets) {
      if (!(await fileFor(preset)).existsSync()) failed.add(preset);
    }
    return failed;
  }

  /// Temp-then-rename: a partial `.srs` would be read as a corrupt rule set and take
  /// the whole config down with it.
  Future<void> _download(String url, File target, {bool allowInsecure = false}) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    // A self-signed mirror is the reachable case for this; see the setting.
    if (allowInsecure) client.badCertificateCallback = (_, _, _) => true;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      final temp = File('${target.path}.tmp');
      try {
        var received = 0;
        await response
            .map((chunk) {
              received += chunk.length;
              if (received > maxBytes) {
                throw HttpException('\$url is larger than a rule set should be');
              }
              return chunk;
            })
            .pipe(temp.openWrite())
            .timeout(_timeout);
        if (temp.lengthSync() == 0) throw const HttpException('empty rule set');
        await temp.rename(target.path);
      } catch (_) {
        // Leaving the partial file behind would have it retried as a complete one
        // the next time round, and a truncated rule set is a fatal config error.
        if (temp.existsSync()) await temp.delete();
        rethrow;
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> delete(RuleSetPreset preset) async {
    final file = await fileFor(preset);
    if (file.existsSync()) await file.delete();
  }

  /// Absolute paths for the presets that are actually on disk, keyed by preset id.
  Future<Map<String, String>> localPaths(List<RuleSetPreset> presets) async {
    final paths = <String, String>{};
    for (final preset in presets) {
      final file = await fileFor(preset);
      if (file.existsSync()) paths[preset.id] = file.path;
    }
    return paths;
  }
}
