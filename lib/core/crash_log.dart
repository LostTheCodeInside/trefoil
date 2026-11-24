import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Records uncaught errors to a file the user can read and share.
///
/// This is what the app offers instead of analytics: there is no server behind it
/// and nothing leaves the device. A VPN client asking to phone home about its own
/// crashes is a bad trade for the person who installed it precisely to control where
/// their traffic goes — but "it closed itself and I do not know why" still needs an
/// answer, and a local file is one.
class CrashLog {
  CrashLog._();

  static final CrashLog instance = CrashLog._();

  /// Capped so a crash loop cannot fill the device. Oldest entries are dropped.
  static const maxBytes = 256 * 1024;
  static const _fileName = 'crash-log.txt';

  bool _installed = false;
  File? _file;

  /// Chains onto whatever Flutter had, so the framework still prints to the console
  /// in debug and nothing that used to be reported stops being reported.
  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object error, StackTrace stack)? _previousPlatformError;

  Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/$_fileName');
  }

  /// Idempotent, so toggling the setting repeatedly cannot stack handlers.
  void install() {
    if (_installed) return;
    _installed = true;
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(record(details.exception, details.stack, context: details.context?.toString()));
      _previousFlutterError?.call(details);
    };
    _previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(record(error, stack));
      return _previousPlatformError?.call(error, stack) ?? true;
    };
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    FlutterError.onError = _previousFlutterError;
    PlatformDispatcher.instance.onError = _previousPlatformError;
  }

  /// Appends one entry. Never throws: a failure to write about a crash must not
  /// become a second crash.
  Future<void> record(Object error, StackTrace? stack, {String? context}) async {
    try {
      final file = await _resolveFile();
      await file.parent.create(recursive: true);
      final entry = StringBuffer()..writeln('--- ${DateTime.now().toIso8601String()} ---');
      if (context != null) entry.writeln('context: $context');
      entry
        ..writeln(error.toString())
        ..writeln(stack?.toString().trimRight() ?? '(no stack trace)')
        ..writeln();
      await file.writeAsString(entry.toString(), mode: FileMode.append, flush: true);
      await _trim(file);
    } catch (_) {
      // Deliberately swallowed; see above.
    }
  }

  /// Keeps the newest [maxBytes] and drops whole entries from the front, so the file
  /// never begins halfway through a stack trace.
  Future<void> _trim(File file) async {
    if (await file.length() <= maxBytes) return;
    final text = await file.readAsString();
    final kept = text.substring(text.length - maxBytes);
    final firstEntry = kept.indexOf('--- ');
    await file.writeAsString(firstEntry < 0 ? kept : kept.substring(firstEntry), flush: true);
  }

  Future<String> read() async {
    try {
      final file = await _resolveFile();
      return file.existsSync() ? await file.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  Future<void> clear() async {
    try {
      final file = await _resolveFile();
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }
}
