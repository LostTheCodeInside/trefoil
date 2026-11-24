import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/wireguard_config.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';

class _Channel extends TunnelChannel {
  final _status = StreamController<TunnelStatus>.broadcast();
  final _logs = StreamController<List<CoreLogEntry>>.broadcast();
  final _groups = StreamController<List<OutboundGroup>>.broadcast();
  final _traffic = StreamController<TrafficSplit>.broadcast();

  @override
  Stream<TunnelStatus> get status => _status.stream;
  @override
  Stream<List<CoreLogEntry>> get logs => _logs.stream;
  @override
  Stream<List<OutboundGroup>> get groups => _groups.stream;
  @override
  Stream<TrafficSplit> get trafficSplit => _traffic.stream;
  @override
  Future<TunnelStatus> currentStatus() async => TunnelStatus.disconnected;

  Future<void> close() async {
    await _status.close();
    await _logs.close();
    await _groups.close();
    await _traffic.close();
  }
}

Outbound _ss(String tag) => ShareLink.parse('ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#$tag')!;

Outbound _wireGuard(String tag) => WireGuardConfig.parse('''
[Interface]
PrivateKey = cGVvcGxlIHNob3VsZCBub3QgdXNlIHRoaXMga2V5ISE=
Address = 10.0.0.2/32

[Peer]
PublicKey = bmZnc3dvcmxkIHB1YmxpYyBrZXkgZm9yIHRlc3RzISE=
Endpoint = 203.0.113.1:51820
AllowedIPs = 0.0.0.0/0
''')!.withTag(tag);

/// sing-box refuses a config that repeats a tag, all of it, so two servers sharing a
/// name meant no connection at all ("duplicate outbound/endpoint tag"). One
/// subscription imported twice got there on its first refresh.
void main() {
  group('Outbound.withUniqueTags', () {
    test('a list with no repeats comes back as it was', () {
      final servers = [_ss('A'), _ss('B')];
      expect(Outbound.withUniqueTags(servers), same(servers));
    });

    test('the first keeps its name and a later one is numbered', () {
      final tags = Outbound.withUniqueTags([_ss('X'), _ss('Y'), _ss('X'), _ss('X')])
          .map((e) => e.tag);
      expect(tags, ['X', 'Y', 'X (2)', 'X (3)']);
    });

    test('a new name is never one another server already has', () {
      final tags = Outbound.withUniqueTags([_ss('X'), _ss('X'), _ss('X (2)')]).map((e) => e.tag);
      expect(tags, ['X', 'X (3)', 'X (2)']);
    });
  });

  test('a profile saved with a repeated name is mended as it loads', () {
    final store = ProfileStore(directory: Directory.systemTemp);
    final encoded = store.encode(
      ProfileData(servers: [_wireGuard('Wireguard'), _ss('Other'), _wireGuard('Wireguard')]),
    );
    expect(store.decode(encoded).servers.map((e) => e.tag), [
      'Wireguard',
      'Other',
      'Wireguard (2)',
    ]);
  });

  test('a repeat that slips through costs one entry, not the whole config', () {
    final first = _wireGuard('Wireguard');
    final config = ConfigBuilder(routing: RoutingSettings.defaults)
        .buildMap(first, servers: [first, _ss('Other'), _wireGuard('Wireguard')]);
    final tags = [
      for (final o in config['outbounds']! as List) (o as Map)['tag'],
      for (final e in config['endpoints']! as List) (e as Map)['tag'],
    ];
    expect(tags.toSet().length, tags.length, reason: '$tags');
    expect(tags.where((t) => t == 'Wireguard'), hasLength(1));
  });

  group('subscriptions', () {
    late HttpServer http;
    late Directory dir;
    late _Channel channel;
    late TunnelController controller;
    var body = '';

    setUp(() async {
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((request) {
        request.response
          ..write(body)
          ..close();
      });
      dir = Directory.systemTemp.createTempSync('trefoil-duplicates');
      channel = _Channel();
      controller = TunnelController(
        channel: channel,
        store: ProfileStore(directory: dir),
      );
      await controller.init();
      body = [
        'ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#Wireguard-example',
        'ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.5:8388#Reality',
      ].join('\n');
    });

    tearDown(() async {
      controller.dispose();
      await channel.close();
      await http.close(force: true);
      dir.deleteSync(recursive: true);
    });

    String url(String path) => 'http://127.0.0.1:${http.port}/$path';

    test('two subscriptions listing the same servers keep apart through a refresh', () async {
      await controller.importSubscription(name: 'one', url: url('a'));
      await controller.importSubscription(name: 'two', url: url('b'));
      final imported = controller.servers.map((e) => e.tag).toList();
      expect(imported.toSet(), hasLength(4));

      for (final subscription in [...controller.subscriptions]) {
        await controller.refreshSubscription(subscription);
      }
      final refreshed = controller.servers.map((e) => e.tag).toList();
      expect(refreshed.toSet(), hasLength(4), reason: '$refreshed');
      // The same names as before the refresh, so a selection or a rule naming one of
      // them still finds it.
      expect(refreshed.toSet(), imported.toSet());
    });

    test('importing an address already there refreshes it instead of adding it again', () async {
      await controller.importSubscription(name: 'one', url: url('a'));
      await controller.importSubscription(name: 'again', url: url('a'));
      expect(controller.subscriptions, hasLength(1));
      expect(controller.servers, hasLength(2));
    });
  });
}
