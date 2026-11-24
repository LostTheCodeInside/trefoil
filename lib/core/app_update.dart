import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Where `scripts/release.sh` publishes releases: the assets of the newest release on
/// GitHub. `latest/download/` always answers with that release's copy of the file.
///
/// Fixed for the life of every installed copy: an app only ever looks where it was
/// built to look, so moving this would strand everyone on the old address.
final releaseManifestUrl = Uri.parse(
  'https://github.com/LostTheCodeInside/trefoil/releases/latest/download/latest.json',
);

/// Where a release download may be redirected to, besides the release server itself.
///
/// GitHub answers an asset address with a redirect to its file storage, on a
/// subdomain of this. A redirect anywhere else is refused.
const releaseRedirectHosts = {'githubusercontent.com'};

/// A newer build of this app, as the release manifest describes it.
@immutable
class AppUpdate {
  const AppUpdate({
    required this.versionName,
    required this.versionCode,
    required this.abi,
    required this.url,
    required this.size,
    required this.sha256,
    this.notes = '',
  });

  final String versionName;

  /// Android's own version number for this exact APK, ABI offset included. This is
  /// what decides "newer", because it is what Android itself compares.
  final int versionCode;
  final String abi;
  final Uri url;
  final int size;

  /// Lowercase hex.
  final String sha256;
  final String notes;

  /// The ceiling on one APK. The real ones are about 100 MB; this only has to stop a
  /// broken or hostile manifest from filling the phone.
  static const maxApkBytes = 512 * 1024 * 1024;

  /// Release notes are shown, not kept; past this they are cut.
  static const maxNotesChars = 8000;

  static final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  /// Picks this phone's build out of a release manifest. Null when the manifest has
  /// none for these [abis] (the phone's, most preferred first), or nothing newer than
  /// [installedVersionCode].
  ///
  /// Throws [FormatException] for anything that is not a well-formed manifest. The
  /// release script writes these, so a malformed one is a bug or tampering, and
  /// either way not something to half-read.
  ///
  /// APK addresses are resolved against [manifestUrl] and must stay beside it: same
  /// scheme, host and port, and the same directory. Whoever can change the manifest
  /// still cannot send the download somewhere else, and on a host shared with other
  /// people's files (GitHub) not to somebody else's either.
  static AppUpdate? pick(
    Object? json, {
    required Uri manifestUrl,
    required List<String> abis,
    required int installedVersionCode,
  }) {
    if (json is! Map) throw const FormatException('the manifest is not a JSON object');
    final versionName = json['versionName'];
    if (versionName is! String || versionName.trim().isEmpty || versionName.length > 64) {
      throw const FormatException('versionName');
    }
    final apks = json['apks'];
    if (apks is! List) throw const FormatException('apks');
    final notes = switch (json['notes']) {
      final String text when text.length > maxNotesChars => '${text.substring(0, maxNotesChars)}…',
      final String text => text,
      _ => '',
    };

    final byAbi = <String, AppUpdate>{};
    for (final entry in apks) {
      final update = _entry(entry, versionName.trim(), notes, manifestUrl);
      byAbi.putIfAbsent(update.abi, () => update);
    }
    for (final abi in abis) {
      if (byAbi[abi] case final update?) {
        return update.versionCode > installedVersionCode ? update : null;
      }
    }
    return null;
  }

  static AppUpdate _entry(Object? entry, String versionName, String notes, Uri manifestUrl) {
    if (entry is! Map) throw const FormatException('apk entry');
    final abi = entry['abi'];
    final versionCode = entry['versionCode'];
    final url = entry['url'];
    final size = entry['size'];
    final sha256 = entry['sha256'];
    if (abi is! String || abi.isEmpty) throw const FormatException('abi');
    if (versionCode is! int || versionCode <= 0) throw const FormatException('versionCode');
    if (size is! int || size <= 0 || size > maxApkBytes) throw const FormatException('size');
    if (sha256 is! String || !_hex64.hasMatch(sha256)) throw const FormatException('sha256');
    if (url is! String || url.isEmpty) throw const FormatException('url');
    final resolved = manifestUrl.resolve(url);
    if (resolved.scheme != manifestUrl.scheme ||
        resolved.host != manifestUrl.host ||
        resolved.port != manifestUrl.port ||
        _directoryOf(resolved) != _directoryOf(manifestUrl)) {
      throw const FormatException('an APK address leaves the release server');
    }
    return AppUpdate(
      versionName: versionName,
      versionCode: versionCode,
      abi: abi,
      url: resolved,
      size: size,
      sha256: sha256.toLowerCase(),
      notes: notes,
    );
  }
}

/// The installed app, as Android reports it.
@immutable
class InstalledBuild {
  const InstalledBuild({required this.versionName, required this.versionCode, required this.abis});

  final String versionName;
  final int versionCode;

  /// Most preferred first.
  final List<String> abis;
}

/// Android, or the checks in front of its installer, refusing something.
///
/// [code] is one of `needs_permission`, `hash_mismatch`, `signature_mismatch`,
/// `wrong_package`, `not_newer`, `manifest_mismatch`, `unreadable`, `bad_path`,
/// `install_failed` or `unsupported`.
class UpdateRejected implements Exception {
  const UpdateRejected(this.code, [this.detail = '']);

  final String code;
  final String detail;

  @override
  String toString() => detail.isEmpty ? code : '$code: $detail';
}

/// What the system installer reported after an install was handed to it.
enum InstallReportKind { waiting, cancelled, failed, installed }

@immutable
class InstallReport {
  const InstallReport(this.kind, [this.detail = '']);

  final InstallReportKind kind;
  final String detail;

  factory InstallReport.fromEvent(Object? event) {
    final map = event is Map ? event : const {};
    final detail = map['detail'] as String? ?? '';
    return switch (map['status']) {
      'waiting' => InstallReport(InstallReportKind.waiting, detail),
      'cancelled' => InstallReport(InstallReportKind.cancelled, detail),
      'installed' => InstallReport(InstallReportKind.installed, detail),
      _ => InstallReport(InstallReportKind.failed, detail),
    };
  }
}

/// The Android side: what is installed, and the installer.
abstract interface class UpdatePlatform {
  Future<InstalledBuild> installed();

  /// Hands [apk] to the installer once Android has checked it is [update]: the same
  /// bytes, this app, newer, and signed by the same key. Throws [UpdateRejected].
  Future<void> install(File apk, AppUpdate update);

  /// Android's "install unknown apps" page for this app.
  Future<void> openInstallSettings();

  Stream<InstallReport> get reports;
}

class ChannelUpdatePlatform implements UpdatePlatform {
  static const _control = MethodChannel('trefoil/update');
  static const _events = EventChannel('trefoil/update/status');

  @override
  Future<InstalledBuild> installed() async {
    final map = await _call<Map<Object?, Object?>>('installed') ?? const {};
    return InstalledBuild(
      versionName: map['versionName'] as String? ?? '',
      versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      abis: [for (final abi in (map['abis'] as List?) ?? const []) abi.toString()],
    );
  }

  @override
  Future<void> install(File apk, AppUpdate update) => _call<void>('install', {
    'path': apk.path,
    'sha256': update.sha256,
    'versionCode': update.versionCode,
  });

  @override
  Future<void> openInstallSettings() => _call<bool>('openInstallSettings');

  @override
  late final Stream<InstallReport> reports = _events.receiveBroadcastStream().map(
    InstallReport.fromEvent,
  );

  static Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _control.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw UpdateRejected(e.code, e.message ?? '');
    } on MissingPluginException {
      throw const UpdateRejected('unsupported');
    }
  }
}

enum UpdateStage {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  needsPermission,
  installing,
  failed,
}

/// Why the last attempt failed, in the terms the screen explains it in.
enum UpdateFailure { network, server, malformed, incomplete, signature, rejected, storage }

/// The path of [url] up to its last slash. Compared as written, not decoded: an
/// encoded slash is part of a name to the server, and must not pass for a directory.
String _directoryOf(Uri url) => url.path.substring(0, url.path.lastIndexOf('/') + 1);

/// Checks the release server, downloads this phone's build and hands it to Android.
///
/// Nothing here can touch the tunnel: a failure costs an error line and nothing else.
class AppUpdater extends ChangeNotifier {
  AppUpdater({
    UpdatePlatform? platform,
    Uri? manifestUrl,
    Future<Directory> Function()? cacheDirectory,
    this.timeout = const Duration(seconds: 20),
    this.redirectHosts = releaseRedirectHosts,
  }) : _platform = platform ?? ChannelUpdatePlatform(),
       manifestUrl = manifestUrl ?? releaseManifestUrl,
       _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  /// The app's one updater. Replaced only by tests, which need it pointed at a server
  /// of their own.
  static AppUpdater instance = AppUpdater();

  final UpdatePlatform _platform;
  final Uri manifestUrl;
  final Future<Directory> Function() _cacheDirectory;

  /// For connecting, and for any gap in a download: a stalled transfer fails rather
  /// than sitting at the same percentage forever.
  final Duration timeout;

  /// Hosts a download may be redirected to; see [releaseRedirectHosts]. Each one
  /// stands for itself and its subdomains.
  final Set<String> redirectHosts;

  /// GitHub takes two redirects to reach a file. More than this is a loop.
  static const maxRedirects = 5;

  /// A manifest is a few hundred bytes; past this it is not one.
  static const maxManifestBytes = 256 * 1024;

  UpdateStage _stage = UpdateStage.idle;
  AppUpdate? _update;
  InstalledBuild? _installed;
  int _received = 0;
  UpdateFailure? _failure;
  String _failureDetail = '';
  bool _quietDone = false;
  bool _leftoversCleared = false;
  bool _cancelled = false;
  HttpClient? _download;
  File? _apk;
  StreamSubscription<InstallReport>? _reports;

  UpdateStage get stage => _stage;
  AppUpdate? get update => _update;
  InstalledBuild? get installed => _installed;
  int get received => _received;
  double get progress => switch (_update) {
    final update? when update.size > 0 => (_received / update.size).clamp(0.0, 1.0),
    _ => 0,
  };
  UpdateFailure? get failure => _failure;
  String get failureDetail => _failureDetail;

  /// False off Android, where there is nothing to install into.
  bool get supported => _supported;
  bool _supported = true;

  bool get _busy => _stage == UpdateStage.checking || _stage == UpdateStage.downloading;

  /// What is installed, without asking the server anything.
  Future<void> loadInstalled() async {
    if (_installed != null || !_supported) return;
    try {
      _installed = await _platform.installed();
    } on UpdateRejected catch (e) {
      if (e.code != 'unsupported') return;
      _supported = false;
    } catch (_) {
      return;
    }
    notifyListeners();
  }

  /// Once per launch, without a word on failure. Returns the update when there is one.
  Future<AppUpdate?> checkQuietly() async {
    if (_quietDone || _stage != UpdateStage.idle) return null;
    _quietDone = true;
    await check(quiet: true);
    return _stage == UpdateStage.available ? _update : null;
  }

  Future<void> check({bool quiet = false}) async {
    if (_busy) return;
    _set(UpdateStage.checking);
    try {
      final installed = _installed ??= await _platform.installed();
      await _clearLeftovers();
      final update = AppUpdate.pick(
        await _fetchManifest(),
        manifestUrl: manifestUrl,
        abis: installed.abis,
        installedVersionCode: installed.versionCode,
      );
      if (update?.versionCode != _update?.versionCode) await _discardApk();
      _update = update;
      _set(update == null ? UpdateStage.upToDate : UpdateStage.available);
    } catch (e) {
      if (e is UpdateRejected && e.code == 'unsupported') {
        _supported = false;
        _set(UpdateStage.idle);
      } else {
        quiet ? _set(UpdateStage.idle) : _fail(e);
      }
    }
  }

  /// Downloads this phone's build, unless it already has, and hands it to Android.
  Future<void> downloadAndInstall() async {
    final update = _update;
    if (update == null || _busy) return;
    try {
      final apk = _apk ??= await _fetchApk(update);
      await _install(apk, update);
    } on _Cancelled {
      _set(UpdateStage.available);
    } catch (e) {
      _fail(e);
    }
  }

  /// Stops a download in progress.
  void cancel() {
    if (_stage != UpdateStage.downloading) return;
    _cancelled = true;
    _download?.close(force: true);
  }

  /// Back from Android's "install unknown apps" page: carry on if it is now allowed.
  Future<void> resume() async {
    final apk = _apk;
    final update = _update;
    if (_stage != UpdateStage.needsPermission || apk == null || update == null) return;
    try {
      await _install(apk, update);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> openInstallSettings() => _platform.openInstallSettings();

  @override
  void dispose() {
    _reports?.cancel();
    _download?.close(force: true);
    super.dispose();
  }

  Future<void> _install(File apk, AppUpdate update) async {
    _reports ??= _platform.reports.listen(_onReport, onError: (Object _) {});
    _set(UpdateStage.installing);
    try {
      await _platform.install(apk, update);
    } on UpdateRejected catch (e) {
      switch (e.code) {
        case 'needs_permission':
          _set(UpdateStage.needsPermission);
          return;
        // Not what was published. Kept, it would be offered again and refused again.
        case 'hash_mismatch' || 'manifest_mismatch' || 'unreadable':
          await _discardApk();
      }
      rethrow;
    }
  }

  void _onReport(InstallReport report) {
    switch (report.kind) {
      case InstallReportKind.waiting:
        _set(UpdateStage.installing);
      // The file is kept, so trying again installs without downloading it again.
      case InstallReportKind.cancelled:
        _set(UpdateStage.available);
      case InstallReportKind.failed:
        _fail(UpdateRejected('install_failed', report.detail));
      case InstallReportKind.installed:
        _set(UpdateStage.upToDate);
    }
  }

  Future<Object?> _fetchManifest() async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      // A cached manifest is a missed release.
      final response = await _get(client, manifestUrl, {
        HttpHeaders.cacheControlHeader: 'no-cache',
      });
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > maxManifestBytes) throw const FormatException('manifest too large');
      }
      return jsonDecode(utf8.decode(bytes.takeBytes()));
    } finally {
      client.close(force: true);
    }
  }

  /// Streams the APK to the cache, checking its length against the manifest as it
  /// goes. Its hash and signature are checked on the Android side, right before the
  /// installer sees it.
  Future<File> _fetchApk(AppUpdate update) async {
    final dir = await _updatesDir();
    await dir.create(recursive: true);
    // Written under a temporary name and renamed once complete, so a crash or a
    // cancel never leaves a half file that looks finished.
    final part = File('${dir.path}/update.apk.part');
    final target = File('${dir.path}/update-${update.versionCode}.apk');
    _received = 0;
    _cancelled = false;
    _set(UpdateStage.downloading);

    final client = _download = HttpClient()..connectionTimeout = timeout;
    IOSink? sink;
    try {
      // The bytes as published. A compressed transfer would arrive with a length that
      // matches nothing, and be refused as incomplete.
      final response = await _get(client, update.url, {
        HttpHeaders.acceptEncodingHeader: 'identity',
      });
      if (response.contentLength >= 0 && response.contentLength != update.size) {
        throw const _Incomplete();
      }
      sink = part.openWrite();
      var shownPercent = -1;
      await for (final chunk in response.timeout(timeout)) {
        _received += chunk.length;
        if (_received > update.size) throw const _Incomplete();
        sink.add(chunk);
        // A rebuild per percent rather than per chunk: chunks arrive by the thousand.
        final percent = _received * 100 ~/ update.size;
        if (percent != shownPercent) {
          shownPercent = percent;
          notifyListeners();
        }
      }
      await sink.close();
      sink = null;
      if (_received != update.size) throw const _Incomplete();
      return await part.rename(target.path);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      if (_cancelled) throw const _Cancelled();
      rethrow;
    } finally {
      client.close(force: true);
      _download = null;
    }
  }

  /// Requests [url] and returns its 200 response, following redirects by hand.
  ///
  /// The client's own redirect handling goes wherever it is told. Here every hop is
  /// checked first: it must keep the scheme, and land on the release server or on one
  /// of [redirectHosts]. Anything else, and any status but 200, throws.
  Future<HttpClientResponse> _get(HttpClient client, Uri url, Map<String, String> headers) async {
    var target = url;
    for (var hop = 0; ; hop++) {
      final request = await client.getUrl(target).timeout(timeout);
      _identify(request);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      if (response.statusCode == HttpStatus.ok) return response;
      final location = response.isRedirect
          ? response.headers.value(HttpHeaders.locationHeader)
          : null;
      // Read to the end so the connection can be used again.
      await response.drain<void>().timeout(timeout);
      if (location == null || hop == maxRedirects) throw _HttpStatus(response.statusCode);
      final next = target.resolve(location);
      if (!_mayRedirectTo(next)) {
        throw const FormatException('a redirect leaves the release server');
      }
      target = next;
    }
  }

  bool _mayRedirectTo(Uri next) {
    if (next.scheme != manifestUrl.scheme) return false;
    if (next.host == manifestUrl.host && next.port == manifestUrl.port) return true;
    return redirectHosts.any((host) => next.host == host || next.host.endsWith('.$host'));
  }

  /// Named, like the subscription fetcher: a CDN in front of the server is more
  /// inclined to challenge a request that says only that it is Dart.
  void _identify(HttpClientRequest request) => request.headers.set(
    HttpHeaders.userAgentHeader,
    'Trefoil/${_installed?.versionName ?? ''} (updater)',
  );

  Future<Directory> _updatesDir() async => Directory('${(await _cacheDirectory()).path}/updates');

  /// A download from an earlier launch is stale by now; if its update was installed,
  /// it is also 100 MB nobody needs.
  Future<void> _clearLeftovers() async {
    if (_leftoversCleared || _apk != null) return;
    _leftoversCleared = true;
    try {
      final dir = await _updatesDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Tidying up, nothing more: next launch, then, and the check goes ahead.
    }
  }

  Future<void> _discardApk() async {
    final apk = _apk;
    _apk = null;
    if (apk == null) return;
    try {
      if (await apk.exists()) await apk.delete();
    } on FileSystemException {
      // Cleared on the next launch.
    }
  }

  void _set(UpdateStage stage) {
    _stage = stage;
    if (stage != UpdateStage.failed) {
      _failure = null;
      _failureDetail = '';
    }
    notifyListeners();
  }

  void _fail(Object error) {
    final (failure, detail) = switch (error) {
      _HttpStatus(:final status) => (UpdateFailure.server, '$status'),
      _Incomplete() => (UpdateFailure.incomplete, ''),
      UpdateRejected(code: 'hash_mismatch') => (UpdateFailure.incomplete, ''),
      UpdateRejected(code: 'signature_mismatch') => (UpdateFailure.signature, ''),
      UpdateRejected(:final detail, :final code) => (
        UpdateFailure.rejected,
        detail.isEmpty ? code : detail,
      ),
      FormatException() => (UpdateFailure.malformed, ''),
      FileSystemException(:final message, :final osError) => (
        UpdateFailure.storage,
        osError?.message ?? message,
      ),
      SocketException() ||
      TimeoutException() ||
      HttpException() ||
      TlsException() => (UpdateFailure.network, '$error'),
      _ => (UpdateFailure.rejected, '$error'),
    };
    _failure = failure;
    _failureDetail = detail;
    _stage = UpdateStage.failed;
    notifyListeners();
  }
}

class _HttpStatus implements Exception {
  const _HttpStatus(this.status);
  final int status;
}

class _Incomplete implements Exception {
  const _Incomplete();
}

class _Cancelled implements Exception {
  const _Cancelled();
}
