import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/app_update.dart';

class _Platform implements UpdatePlatform {
  _Platform({this.supported = true});

  final bool supported;
  final reportsController = StreamController<InstallReport>.broadcast();
  final installs = <(String path, int versionCode)>[];

  /// Thrown by the next install instead of accepting it.
  UpdateRejected? refuseNext;

  @override
  Future<InstalledBuild> installed() async {
    if (!supported) throw const UpdateRejected('unsupported');
    return InstalledBuild(
      versionName: '1.0.0',
      versionCode: 2001,
      abis: const ['arm64-v8a', 'armeabi-v7a'],
    );
  }

  @override
  Future<void> install(File apk, AppUpdate update) async {
    final refusal = refuseNext;
    refuseNext = null;
    if (refusal != null) throw refusal;
    installs.add((apk.path, update.versionCode));
  }

  @override
  Future<void> openInstallSettings() async {}

  @override
  Stream<InstallReport> get reports => reportsController.stream;
}

/// Serves [files] by path, counting requests. [shortBy] sends that many bytes less
/// than an APK's length, without a Content-Length, the way a dropped transfer looks.
class _Server {
  _Server._(this._server, this.files);

  final HttpServer _server;
  final Map<String, List<int>> files;
  final hits = <String, int>{};
  int shortBy = 0;

  /// Paths answered with a redirect to the address given.
  final redirects = <String, String>{};

  static Future<_Server> start(Map<String, List<int>> files) async {
    final server = _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), files);
    server._server.listen(server._handle);
    return server;
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    hits[path] = (hits[path] ?? 0) + 1;
    final body = files[path];
    if (redirects[path] case final target?) {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, target);
    } else if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
    } else if (shortBy > 0 && path.endsWith('.apk')) {
      request.response.add(body.sublist(0, body.length - shortBy));
    } else {
      request.response.contentLength = body.length;
      request.response.add(body);
    }
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

final _apk = List<int>.generate(300 * 1024, (i) => i % 251);
final _sha = 'a' * 64;

Map<String, Object?> _manifest({
  int versionCode = 2002,
  String url = 'trefoil-1.1.0-arm64-v8a.apk',
  int? size,
  Object? notes = 'Faster.',
  Map<String, Object?> extra = const {},
}) => {
  'schema': 1,
  'versionName': '1.1.0',
  'build': 2,
  'notes': notes,
  'apks': [
    {
      'abi': 'armeabi-v7a',
      'versionCode': 1002,
      'url': 'trefoil-1.1.0-armeabi-v7a.apk',
      'size': 10,
      'sha256': _sha,
    },
    {
      'abi': 'arm64-v8a',
      'versionCode': versionCode,
      'url': url,
      'size': size ?? _apk.length,
      'sha256': _sha,
    },
  ],
  ...extra,
};

void main() {
  group('AppUpdate.pick', () {
    AppUpdate? pick(
      Object? json, {
      List<String> abis = const ['arm64-v8a', 'armeabi-v7a'],
      int installed = 2001,
    }) => AppUpdate.pick(
      json,
      manifestUrl: releaseManifestUrl,
      abis: abis,
      installedVersionCode: installed,
    );

    test("takes the phone's most preferred ABI, from the release server", () {
      final update = pick(_manifest())!;
      expect(update.abi, 'arm64-v8a');
      expect(update.versionCode, 2002);
      expect(
        update.url.toString(),
        'https://github.com/LostTheCodeInside/trefoil/releases/latest/download/'
        'trefoil-1.1.0-arm64-v8a.apk',
      );
      expect(update.notes, 'Faster.');
    });

    test('nothing newer, or nothing for this phone, is no update', () {
      expect(pick(_manifest(), installed: 2002), isNull);
      expect(pick(_manifest(), abis: const ['x86_64']), isNull);
    });

    // Whoever can change the manifest still must not be able to send the download
    // anywhere else, nor over plain HTTP.
    test('an APK address off the release server is refused', () {
      for (final url in [
        'https://elsewhere.example/trefoil.apk',
        '//elsewhere.example/trefoil.apk',
        'http://github.com/LostTheCodeInside/trefoil/releases/latest/download/trefoil.apk',
        'https://github.com:8443/LostTheCodeInside/trefoil/releases/latest/download/trefoil.apk',
        // The same host holds everybody's files, so the directory has to match too.
        'https://github.com/someone-else/trefoil/releases/latest/download/trefoil.apk',
        '/someone-else/trefoil/releases/latest/download/trefoil.apk',
        '../../download/v9/trefoil.apk',
        'sub/trefoil.apk',
        // An encoded slash is not a directory.
        '..%2F..%2F..%2F..%2Fsomeone-else/trefoil.apk',
      ]) {
        expect(() => pick(_manifest(url: url)), throwsFormatException, reason: url);
      }
    });

    test('a malformed manifest is refused rather than half-read', () {
      expect(() => pick('not a manifest'), throwsFormatException);
      expect(() => pick({'versionName': '1.1.0'}), throwsFormatException);
      expect(() => pick(_manifest(size: 0)), throwsFormatException);
      expect(() => pick(_manifest(size: AppUpdate.maxApkBytes + 1)), throwsFormatException);
      expect(
        () => pick({
          'versionName': '1.1.0',
          'apks': [
            {'abi': 'arm64-v8a', 'versionCode': 2002, 'url': 'a.apk', 'size': 1, 'sha256': 'nope'},
          ],
        }),
        throwsFormatException,
      );
    });

    test('unknown fields are ignored and long notes are cut', () {
      final update = pick(_manifest(notes: 'x' * 9000, extra: {'futureField': true}))!;
      expect(update.notes.length, AppUpdate.maxNotesChars + 1);
    });
  });

  group('AppUpdater', () {
    late _Server server;
    late _Platform platform;
    late Directory cache;
    late AppUpdater updater;

    setUp(() async {
      server = await _Server.start({
        '/trefoil/latest.json': utf8.encode(jsonEncode(_manifest())),
        '/trefoil/trefoil-1.1.0-arm64-v8a.apk': _apk,
      });
      platform = _Platform();
      cache = Directory.systemTemp.createTempSync('trefoil-update');
      updater = AppUpdater(
        platform: platform,
        manifestUrl: server.url('/trefoil/latest.json'),
        cacheDirectory: () async => cache,
      );
    });

    tearDown(() async {
      updater.dispose();
      await server.close();
      cache.deleteSync(recursive: true);
    });

    List<String> leftovers() => [
      for (final file in Directory('${cache.path}/updates').listSync()) file.uri.pathSegments.last,
    ];

    test('downloads the exact bytes and hands them to Android', () async {
      await updater.check();
      expect(updater.stage, UpdateStage.available);
      expect(updater.update!.versionName, '1.1.0');

      await updater.downloadAndInstall();
      expect(platform.installs, hasLength(1));
      expect(File(platform.installs.single.$1).readAsBytesSync(), _apk);
      expect(updater.progress, 1.0);
      expect(updater.stage, UpdateStage.installing);
    });

    // GitHub answers an asset address with a redirect to its storage host.
    test('a redirect on the release server or to an allowed host is followed', () async {
      final storage = 'http://localhost:${server.url('/').port}';
      server.files['/v1/latest.json'] = server.files['/trefoil/latest.json']!;
      server.files['/store/app.apk'] = _apk;
      server.redirects['/trefoil/latest.json'] = '/v1/latest.json';
      server.redirects['/trefoil/trefoil-1.1.0-arm64-v8a.apk'] = '$storage/store/app.apk';
      updater.dispose();
      updater = AppUpdater(
        platform: platform,
        manifestUrl: server.url('/trefoil/latest.json'),
        cacheDirectory: () async => cache,
        redirectHosts: const {'localhost'},
      );

      await updater.check();
      expect(updater.stage, UpdateStage.available);
      await updater.downloadAndInstall();
      expect(File(platform.installs.single.$1).readAsBytesSync(), _apk);
    });

    test('a redirect to any other host is refused', () async {
      // Reaches the same server, but by a name nobody allowed.
      server.redirects['/trefoil/trefoil-1.1.0-arm64-v8a.apk'] =
          'http://localhost:${server.url('/').port}/trefoil/elsewhere.apk';
      server.files['/trefoil/elsewhere.apk'] = _apk;

      await updater.check();
      await updater.downloadAndInstall();
      expect(updater.stage, UpdateStage.failed);
      expect(updater.failure, UpdateFailure.malformed);
      expect(server.hits['/trefoil/elsewhere.apk'], isNull);
      expect(platform.installs, isEmpty);
    });

    test('a redirect loop ends', () async {
      server.redirects['/trefoil/latest.json'] = '/trefoil/latest.json';
      await updater.check();
      expect(updater.stage, UpdateStage.failed);
      expect(server.hits['/trefoil/latest.json'], AppUpdater.maxRedirects + 1);
    });

    test('a short download is refused and leaves nothing behind', () async {
      server.shortBy = 1000;
      await updater.check();
      await updater.downloadAndInstall();

      expect(updater.stage, UpdateStage.failed);
      expect(updater.failure, UpdateFailure.incomplete);
      expect(platform.installs, isEmpty);
      expect(leftovers(), isEmpty);
    });

    test('asks for permission, then carries on by itself', () async {
      platform.refuseNext = const UpdateRejected('needs_permission');
      await updater.check();
      await updater.downloadAndInstall();
      expect(updater.stage, UpdateStage.needsPermission);

      await updater.resume();
      expect(platform.installs, hasLength(1));
      expect(updater.stage, UpdateStage.installing);
    });

    test('a declined confirmation keeps the download for the next try', () async {
      await updater.check();
      await updater.downloadAndInstall();
      platform.reportsController.add(const InstallReport(InstallReportKind.cancelled));
      await pumpEventQueue();
      expect(updater.stage, UpdateStage.available);

      await updater.downloadAndInstall();
      expect(platform.installs, hasLength(2));
      expect(server.hits['/trefoil/trefoil-1.1.0-arm64-v8a.apk'], 1);
    });

    test('a corrupt download is thrown away and fetched again', () async {
      platform.refuseNext = const UpdateRejected('hash_mismatch');
      await updater.check();
      await updater.downloadAndInstall();
      expect(updater.failure, UpdateFailure.incomplete);
      expect(leftovers(), isEmpty);

      await updater.check();
      await updater.downloadAndInstall();
      expect(platform.installs, hasLength(1));
      expect(server.hits['/trefoil/trefoil-1.1.0-arm64-v8a.apk'], 2);
    });

    test('a different signing key is named as such', () async {
      platform.refuseNext = const UpdateRejected('signature_mismatch');
      await updater.check();
      await updater.downloadAndInstall();
      expect(updater.failure, UpdateFailure.signature);
    });

    test('a server error is reported with its status, but not on the quiet check', () async {
      server.files.remove('/trefoil/latest.json');

      expect(await updater.checkQuietly(), isNull);
      expect(updater.stage, UpdateStage.idle);
      expect(updater.failure, isNull);

      await updater.check();
      expect(updater.failure, UpdateFailure.server);
      expect(updater.failureDetail, '404');
    });

    test('the quiet check runs once per launch', () async {
      expect(await updater.checkQuietly(), isNotNull);
      expect(await updater.checkQuietly(), isNull);
      expect(server.hits['/trefoil/latest.json'], 1);
    });

    test('off Android it stays out of sight', () async {
      updater.dispose();
      updater = AppUpdater(
        platform: _Platform(supported: false),
        manifestUrl: server.url('/trefoil/latest.json'),
        cacheDirectory: () async => cache,
      );
      await updater.check();
      expect(updater.supported, isFalse);
      expect(updater.stage, UpdateStage.idle);
      expect(server.hits, isEmpty);
    });
  });
}
