import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';

/// Enough of the native side for the controller to run against a temp directory.
///
/// Removing a server tells the service to forget its traffic total, so the channel
/// has to answer that call — the real one throws off-device, which the controller
/// already tolerates, but then the test would be exercising the catch rather than
/// the removal.
class _Channel extends TunnelChannel {
  final _status = StreamController<TunnelStatus>.broadcast();
  final _logs = StreamController<List<CoreLogEntry>>.broadcast();
  final _groups = StreamController<List<OutboundGroup>>.broadcast();
  final _traffic = StreamController<TrafficSplit>.broadcast();

  final forgotten = <String>[];

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

  @override
  Future<void> forgetServerUsage(String tag) async => forgotten.add(tag);

  Future<void> close() async {
    await _status.close();
    await _logs.close();
    await _groups.close();
    await _traffic.close();
  }
}

/// Undo for the two removals a mis-tap can reach: a server row, and a swiped rule.
///
/// Both restore by position rather than by appending. For a rule that is the whole
/// meaning of the list — the core takes the first match — and for a server it is
/// what stops the row reappearing somewhere the eye is not.
void main() {
  late Directory dir;
  late _Channel channel;
  late TunnelController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trefoil-undo');
    channel = _Channel();
    controller = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    await controller.init();
  });

  tearDown(() async {
    controller.dispose();
    await channel.close();
    dir.deleteSync(recursive: true);
  });

  Outbound server(String tag) =>
      ShareLink.parse('ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#$tag')!;

  Future<void> seed(List<String> tags) async {
    for (final tag in tags) {
      await controller.addFromLink('ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#$tag');
    }
    expect(controller.servers.map((e) => e.tag), tags);
  }

  test('removing a server reports where it was', () async {
    await seed(['a', 'b', 'c']);
    expect(await controller.removeServer(server('b')), 1);
    expect(controller.servers.map((e) => e.tag), ['a', 'c']);
  });

  test('undo puts the server back in its old place, not at the end', () async {
    await seed(['a', 'b', 'c']);
    final index = await controller.removeServer(server('b'));
    await controller.restoreServer(server('b'), index);
    expect(controller.servers.map((e) => e.tag), ['a', 'b', 'c']);
  });

  test('a restored server survives a reload', () async {
    await seed(['a', 'b']);
    final index = await controller.removeServer(server('a'));
    await controller.restoreServer(server('a'), index);

    final reloaded = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    addTearDown(reloaded.dispose);
    await reloaded.init();
    expect(reloaded.servers.map((e) => e.tag), ['a', 'b']);
  });

  test('removing a server that is already gone reports no position', () async {
    // The snackbar keys its undo off this. A second tap on a stale row used to reach
    // removeServer again; offering to restore something nothing removed would then
    // put a duplicate back.
    await seed(['a']);
    expect(await controller.removeServer(server('a')), 0);
    expect(await controller.removeServer(server('a')), -1);
  });

  test('undo does not duplicate a tag that came back on its own', () async {
    // A subscription refresh can land while the snackbar is still up. The tag is
    // taken, so the restore is dropped rather than adding a second row under it.
    await seed(['a', 'b']);
    final index = await controller.removeServer(server('a'));
    await controller.addFromLink('ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#a');
    await controller.restoreServer(server('a'), index);
    expect(controller.servers.where((e) => e.tag == 'a'), hasLength(1));
  });

  test('an undone rule goes back at its old index', () async {
    // Order decides which rule fires. Appending the restored one would leave the
    // list looking whole while routing traffic somewhere else.
    const rules = [
      RoutingRule(match: RuleMatch.domain, value: 'first.example', action: RuleAction.block),
      RoutingRule(match: RuleMatch.domain, value: 'second.example', action: RuleAction.direct),
      RoutingRule(match: RuleMatch.domain, value: 'third.example', action: RuleAction.proxy),
    ];
    for (final rule in rules) {
      await controller.addRule(rule);
    }

    await controller.removeRuleAt(1);
    expect(controller.routing.rules.map((e) => e.value), ['first.example', 'third.example']);

    await controller.restoreRuleAt(1, rules[1]);
    expect(controller.routing.rules.map((e) => e.value), [
      'first.example',
      'second.example',
      'third.example',
    ]);
  });
}
