import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';

class _FakeChannel extends TunnelChannel {
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

/// A rule's position is part of its meaning: the core takes the first match, so a
/// rule that moves to the end of the list can stop applying without its own text
/// changing. Editing has to replace in place, which is what these check.
void main() {
  late Directory dir;
  late _FakeChannel channel;
  late TunnelController controller;

  const first = RoutingRule(
    match: RuleMatch.domainSuffix,
    value: 'first.example',
    action: RuleAction.direct,
  );
  const second = RoutingRule(
    match: RuleMatch.domainSuffix,
    value: 'second.example',
    action: RuleAction.proxy,
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trefoil-rules');
    channel = _FakeChannel();
    controller = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    await controller.init();
    await controller.addRule(first);
    await controller.addRule(second);
  });

  tearDown(() async {
    controller.dispose();
    await channel.close();
    dir.deleteSync(recursive: true);
  });

  test('an edit replaces in place rather than appending', () async {
    await controller.updateRuleAt(0, first.copyWith(value: 'changed.example'));

    expect(controller.routing.rules.length, 2);
    expect(controller.routing.rules[0].value, 'changed.example');
    expect(controller.routing.rules[1].value, 'second.example');
  });

  test('an edit can change the match and action too', () async {
    await controller.updateRuleAt(
      1,
      second.copyWith(match: RuleMatch.port, value: '443', action: RuleAction.block),
    );

    final edited = controller.routing.rules[1];
    expect(edited.match, RuleMatch.port);
    expect(edited.value, '443');
    expect(edited.action, RuleAction.block);
    // The one before it is untouched.
    expect(controller.routing.rules[0].value, 'first.example');
  });

  test('an index that is not there is ignored rather than throwing', () async {
    await controller.updateRuleAt(9, first);
    await controller.updateRuleAt(-1, first);
    expect(controller.routing.rules.length, 2);
    expect(controller.routing.rules[0].value, 'first.example');
  });

  test('the edit survives a reload from disk', () async {
    await controller.updateRuleAt(0, first.copyWith(value: 'persisted.example'));

    final reopened = TunnelController(
      channel: _FakeChannel(),
      store: ProfileStore(directory: dir),
    );
    addTearDown(reopened.dispose);
    await reopened.init();

    expect(reopened.routing.rules[0].value, 'persisted.example');
    expect(reopened.routing.rules[1].value, 'second.example');
  });
}
