import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/home_screen.dart';
import 'package:trefoil/ui/servers_screen.dart';

/// Streams that stay quiet, so a screen can be mounted without a platform behind it.
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

/// What the app says out loud.
///
/// The screens lean on symbols to say things compactly — an arrow for a direction, a
/// container colour for the server in use, an em dash for a figure that has not
/// arrived. None of those reach a screen reader, and the figures they qualify are
/// meaningless without them: two byte counts in a row, told apart by nothing.
///
/// These tests read the semantics tree rather than the pixels, which is the only
/// place the difference shows.
void main() {
  Future<TunnelController> mount(WidgetTester tester, Widget home, {ProfileData? seed}) async {
    final dir = Directory.systemTemp.createTempSync('trefoil-a11y');
    addTearDown(() => dir.deleteSync(recursive: true));

    final channel = _Channel();
    addTearDown(channel.close);
    final controller = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    addTearDown(controller.dispose);

    // Seeded on disk rather than through the controller: every mutator persists, and
    // a persist awaited from a testWidgets body deadlocks against the fake clock.
    await tester.runAsync(() async {
      if (seed != null) await ProfileStore(directory: dir).save(seed);
      await controller.init();
    });

    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Outbound server(String tag) => Outbound(
    tag: tag,
    type: 'vless',
    json: {'type': 'vless', 'tag': tag, 'server': '203.0.113.7', 'server_port': 443},
  );

  testWidgets('the server in use is announced as selected, not only coloured', (tester) async {
    final handle = tester.ensureSemantics();

    await mount(
      tester,
      const ServersScreen(),
      seed: ProfileData(servers: [server('alpha'), server('beta')], selectedTag: 'alpha'),
    );

    SemanticsNode tileFor(String tag) =>
        tester.getSemantics(find.ancestor(of: find.text(tag), matching: find.byType(ListTile)));

    expect(tileFor('alpha'), isSemantics(isSelected: true));
    // The other one must not claim it, or "selected" stops meaning anything.
    expect(tileFor('beta'), isSemantics(isSelected: false));
    handle.dispose();
  });

  testWidgets('the address line is spoken with a comma, not an interpunct', (tester) async {
    final handle = tester.ensureSemantics();

    await mount(
      tester,
      const ServersScreen(),
      seed: ProfileData(servers: [server('alpha')], selectedTag: 'alpha'),
    );

    // Written with the interpunct, which reads as either silence or "middle dot".
    expect(find.text('VLESS · 203.0.113.7:443'), findsOneWidget);
    // A RegExp because ListTile merges its title and subtitle into one node, so the
    // label under test arrives as part of a longer utterance.
    expect(find.bySemanticsLabel(RegExp(r'VLESS, 203\.0\.113\.7:443')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('VLESS · ')), findsNothing);
    handle.dispose();
  });

  testWidgets('a figure that has not arrived says so, rather than an em dash', (tester) async {
    final handle = tester.ensureSemantics();

    // Nothing has connected, so the core has reported no traffic and both counters
    // stand at the placeholder.
    await mount(tester, HomeScreen(onAddServer: () {}));

    expect(find.text('—'), findsNWidgets(2));
    // "No reading yet", twice: once for each direction. Spoken, the em dash is
    // either nothing at all or the words "em dash".
    expect(find.bySemanticsLabel(RegExp('No reading yet')), findsNWidgets(2));
    // Exact, not a pattern: an em dash used as punctuation inside a sentence is
    // fine, and the empty-state line has one.
    expect(find.bySemanticsLabel('—'), findsNothing);
    handle.dispose();
  });
}
