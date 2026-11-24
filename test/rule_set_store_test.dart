import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/rule_set_store.dart';

/// Serves rule sets over loopback so the store exercises its real HTTP path.
class _Server {
  _Server(this._socket) {
    _socket.listen((request) async {
      // A handler that deliberately breaks the connection must not surface as an
      // unhandled async error and fail the test that asked for it.
      try {
        final behaviour = script[request.uri.path];
        if (behaviour == null) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        await behaviour(request);
      } catch (_) {}
    });
  }

  final HttpServer _socket;

  /// Keyed by request path.
  final Map<String, Future<void> Function(HttpRequest)> script = {};

  String url(String path) => 'http://127.0.0.1:${_socket.port}$path';

  Future<void> close() => _socket.close(force: true);

  static Future<_Server> start() async =>
      _Server(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
}

RuleSetPreset preset(String id) =>
    RuleSetPreset(id: id, label: id, description: id, action: RuleAction.direct, isIpSet: false);

void main() {
  late Directory dir;
  late _Server server;
  late RuleSetStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trefoil-rules');
    server = await _Server.start();
    store = RuleSetStore(directory: dir);
  });

  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  /// The derived path for a preset, which is what the store will ask for.
  String pathFor(String id) => '/sing-geosite/rule-set/$id.srs';

  Future<List<RuleSetPreset>> ensure(
    List<RuleSetPreset> presets, {
    bool force = false,
    Duration? within,
  }) => store.ensureAvailable(
    presets,
    force: force,
    within: within,
    source: RuleSetSource.custom,
    base: server.url(''),
  );

  Future<void> ok(HttpRequest request) async {
    request.response.add(List.filled(64, 7));
    await request.response.close();
  }

  test('downloads what is missing and reports nothing failed', () async {
    server.script[pathFor('a')] = ok;
    final failed = await ensure([preset('a')]);
    expect(failed, isEmpty);
    expect((await store.fileFor(preset('a'))).lengthSync(), 64);
  });

  test('a preset that cannot be fetched at all is reported', () async {
    // It must be reported rather than referenced: sing-box refuses to start when a
    // rule set file named in the config is not on disk.
    // Nothing is registered for it, so the server answers 404.
    final failed = await ensure([preset('missing')]);
    expect(failed.map((e) => e.id), ['missing']);
  });

  test('a stale copy survives a failed refresh', () async {
    server.script[pathFor('a')] = ok;
    await ensure([preset('a')]);
    server.script.remove(pathFor('a'));

    final failed = await ensure([preset('a')], force: true);
    expect(failed, isEmpty, reason: 'an old list beats no list');
    expect((await store.fileFor(preset('a'))).existsSync(), isTrue);
  });

  test('a failed download leaves no partial file behind', () async {
    // A partial .srs parses as a corrupt rule set and takes the whole config down
    // with it, so a failed transfer must leave nothing rather than something. An
    // empty 200 -- which mirrors do serve -- is the reachable version of that.
    server.script[pathFor('a')] = (request) async => request.response.close();

    final failed = await ensure([preset('a')]);
    expect(failed.map((e) => e.id), ['a']);

    final target = await store.fileFor(preset('a'));
    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.tmp').existsSync(), isFalse);
  });

  test('a slow mirror does not hold the caller past its deadline', () async {
    // This is what makes the connect button responsive on a first run: whatever has
    // not arrived keeps downloading and is picked up next time.
    final blocked = Completer<void>();
    addTearDown(() {
      if (!blocked.isCompleted) blocked.complete();
    });
    server.script[pathFor('slow')] = (request) async {
      await blocked.future;
      await request.response.close();
    };

    final clock = Stopwatch()..start();
    final failed = await ensure([preset('slow')], within: const Duration(milliseconds: 300));
    clock.stop();

    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    expect(failed.map((e) => e.id), ['slow'], reason: 'nothing landed, so it is unavailable');
  });

  test('presets are fetched concurrently, not one after another', () async {
    // Sequentially these would take at least 3 x 200ms; the point of the change is
    // that a first connect does not pay that per list.
    final gate = Completer<void>();
    var inFlight = 0;
    var peak = 0;
    for (final id in ['a', 'b', 'c']) {
      server.script[pathFor(id)] = (request) async {
        inFlight++;
        peak = peak > inFlight ? peak : inFlight;
        await gate.future;
        inFlight--;
        request.response.add(List.filled(8, 1));
        await request.response.close();
      };
    }

    final done = ensure([
      for (final id in ['a', 'b', 'c']) preset(id),
    ]);
    // Let all three reach the server before releasing any of them.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    gate.complete();
    expect(await done, isEmpty);
    expect(peak, 3);
  });

  group('sources', () {
    test('each one points at the same file by a different route', () {
      final p = preset('geosite-cn');
      expect(
        p.urlFor(RuleSetSource.official, ''),
        'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs',
      );
      expect(
        p.urlFor(RuleSetSource.jsdelivr, ''),
        'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs',
      );
      expect(
        p.urlFor(RuleSetSource.custom, 'https://mirror.example.com/'),
        'https://mirror.example.com/sing-geosite/rule-set/geosite-cn.srs',
      );
    });

    test('IP sets come from the other repository', () {
      // They are published separately, and getting this wrong is a 404 on exactly
      // the lists a country preset needs.
      expect(preset('geoip-cn').repository, 'sing-geoip');
      expect(preset('geosite-cn').repository, 'sing-geosite');
    });

    test('a custom base with no address falls back rather than building nonsense', () {
      expect(
        preset('geoip-id').urlFor(RuleSetSource.custom, '   '),
        startsWith('https://raw.githubusercontent.com/'),
      );
    });

    test('every catalog entry resolves under every source', () {
      for (final entry in RuleSetPreset.catalog) {
        for (final source in RuleSetSource.values) {
          final url = entry.urlFor(source, 'https://mirror.example.com');
          expect(Uri.tryParse(url)?.host, isNotEmpty, reason: '${entry.id} / $source');
          expect(url, endsWith('.srs'));
        }
      }
    });
  });
}
