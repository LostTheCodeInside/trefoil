import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/servers_screen.dart';

class _Channel extends TunnelChannel {
  final _status = StreamController<TunnelStatus>.broadcast();
  final _logs = StreamController<List<CoreLogEntry>>.broadcast();
  final groups$ = StreamController<List<OutboundGroup>>.broadcast();
  final _traffic = StreamController<TrafficSplit>.broadcast();

  @override
  Stream<TunnelStatus> get status => _status.stream;
  @override
  Stream<List<CoreLogEntry>> get logs => _logs.stream;
  @override
  Stream<List<OutboundGroup>> get groups => groups$.stream;
  @override
  Stream<TrafficSplit> get trafficSplit => _traffic.stream;

  @override
  Future<TunnelStatus> currentStatus() async => TunnelStatus.disconnected;

  /// The core's latency report, one reading per server.
  void report(Map<String, int> delays) => groups$.add([
    OutboundGroup(
      tag: 'proxy',
      type: 'selector',
      selected: 'alpha',
      selectable: true,
      items: [
        for (final entry in delays.entries)
          OutboundItem(tag: entry.key, type: 'vless', delayMs: entry.value, testedAt: 1),
      ],
    ),
  ]);

  Future<void> close() async {
    await _status.close();
    await _logs.close();
    await groups$.close();
    await _traffic.close();
  }
}

/// Sorted by latency, the list must not move while readings are still arriving.
///
/// During a test they land one server at a time. Re-sorting on each one slid rows
/// out from under the user's finger, so a tap aimed at one server selected whichever
/// had just moved into its place.
void main() {
  late _Channel channel;

  Future<void> mount(WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync('trefoil-order');
    addTearDown(() => dir.deleteSync(recursive: true));
    channel = _Channel();
    addTearDown(channel.close);
    final controller = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    addTearDown(controller.dispose);

    Outbound server(String tag) => Outbound(
      tag: tag,
      type: 'vless',
      json: {'type': 'vless', 'tag': tag, 'server': '203.0.113.7', 'server_port': 443},
    );
    await tester.runAsync(() async {
      await ProfileStore(directory: dir).save(
        ProfileData(
          servers: [server('alpha'), server('bravo'), server('charlie')],
          selectedTag: 'alpha',
        ),
      );
      await controller.init();
    });

    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ServersScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Latency'));
    await tester.pumpAndSettle();
  }

  /// The report reaches the screen a microtask after it is sent, and a pump with
  /// no frame pending does not draw one; the second pump is the frame.
  Future<void> deliver(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  List<String> order(WidgetTester tester) {
    final tags = ['alpha', 'bravo', 'charlie'];
    double top(String tag) => tester.getTopLeft(find.text(tag)).dy;
    tags.sort((a, b) => top(a).compareTo(top(b)));
    return tags;
  }

  testWidgets('readings arriving do not move the rows at once', (tester) async {
    await mount(tester);
    expect(order(tester), ['alpha', 'bravo', 'charlie']);

    channel.report({'alpha': 300, 'bravo': 100, 'charlie': 200});
    await deliver(tester);
    expect(order(tester), ['alpha', 'bravo', 'charlie'], reason: 'held while readings arrive');

    // More arriving keeps it held: the wait starts again from the newest one.
    await tester.pump(const Duration(milliseconds: 1000));
    channel.report({'alpha': 300, 'bravo': 100, 'charlie': 150});
    await deliver(tester);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(order(tester), ['alpha', 'bravo', 'charlie']);

    // Then settled once, when they stop.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(order(tester), ['bravo', 'charlie', 'alpha']);
  });

  testWidgets('the order is never settled under a finger', (tester) async {
    await mount(tester);
    channel.report({'alpha': 300, 'bravo': 100, 'charlie': 200});
    await deliver(tester);

    final finger = await tester.startGesture(tester.getCenter(find.text('charlie')));
    await tester.pump(const Duration(seconds: 3));
    expect(order(tester), ['alpha', 'bravo', 'charlie'], reason: 'a finger is on the list');

    await finger.up();
    await tester.pump(const Duration(seconds: 2));
    expect(order(tester), ['bravo', 'charlie', 'alpha']);
  });
}
