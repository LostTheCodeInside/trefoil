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

/// The server list is split by where each server came from: the ones added by hand
/// first, then one group per subscription, each under its name.
void main() {
  Outbound server(String tag, [String? subscriptionId]) => Outbound(
    tag: tag,
    type: 'vless',
    subscriptionId: subscriptionId,
    json: {'type': 'vless', 'tag': tag, 'server': '203.0.113.7', 'server_port': 443},
  );

  Subscription subscription(String id, String name) => Subscription(
    id: id,
    name: name,
    url: 'https://sub.example/$id',
    // Fresh, so opening the screen does not go and fetch it.
    updatedAt: DateTime.now(),
  );

  Future<void> mount(WidgetTester tester, ProfileData profile) async {
    final dir = Directory.systemTemp.createTempSync('trefoil-groups');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = _Channel();
    addTearDown(channel.close);
    final controller = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    addTearDown(controller.dispose);
    await tester.runAsync(() async {
      await ProfileStore(directory: dir).save(profile);
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
  }

  double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

  void expectInOrder(WidgetTester tester, List<String> texts) {
    final tops = [for (final text in texts) top(tester, text)];
    for (var i = 1; i < tops.length; i++) {
      expect(
        tops[i],
        greaterThan(tops[i - 1]),
        reason: '"${texts[i]}" is not below "${texts[i - 1]}"',
      );
    }
  }

  testWidgets('hand-added servers come first, then each subscription under its name', (
    tester,
  ) async {
    await mount(
      tester,
      ProfileData(
        servers: [
          server('Sub B one', 'b'),
          server('Mine'),
          server('Sub A two', 'a'),
          server('Sub A one', 'a'),
        ],
        subscriptions: [subscription('a', 'Provider A'), subscription('b', 'Provider B')],
      ),
    );

    // Subscriptions in the order they were added, not the order their servers are
    // stored in; the chosen sort inside each.
    expectInOrder(tester, [
      'Added manually',
      'Mine',
      'Provider A',
      'Sub A one',
      'Sub A two',
      'Provider B',
      'Sub B one',
    ]);
    // A heading to a screen reader, carrying what is under it.
    expect(find.bySemanticsLabel('Provider A, 2 servers'), findsOneWidget);
  });

  testWidgets('without subscriptions the list stays plain', (tester) async {
    await mount(tester, ProfileData(servers: [server('Alpha'), server('Bravo')]));

    expect(find.text('Added manually'), findsNothing);
    expectInOrder(tester, ['Alpha', 'Bravo']);
  });

  testWidgets('a server whose subscription is gone stays in sight with the hand-added ones', (
    tester,
  ) async {
    await mount(
      tester,
      ProfileData(
        servers: [server('Orphan', 'gone'), server('Sub A one', 'a')],
        subscriptions: [subscription('a', 'Provider A')],
      ),
    );

    expectInOrder(tester, ['Added manually', 'Orphan', 'Provider A', 'Sub A one']);
  });

  testWidgets('a search leaves out groups with nothing matching', (tester) async {
    await mount(
      tester,
      ProfileData(
        servers: [
          for (var i = 1; i <= 4; i++) server('Mine $i'),
          for (var i = 1; i <= 4; i++) server('Theirs $i', 'a'),
        ],
        subscriptions: [subscription('a', 'Provider A')],
      ),
    );

    await tester.enterText(find.byType(TextField), 'mine');
    await tester.pumpAndSettle();

    expect(find.text('Added manually'), findsOneWidget);
    expect(find.text('Provider A'), findsNothing);
  });

  testWidgets('a group folds away, and says when the chosen server is inside', (tester) async {
    await mount(
      tester,
      ProfileData(
        servers: [server('Mine'), server('Sub A one', 'a'), server('Sub A two', 'a')],
        subscriptions: [subscription('a', 'Provider A')],
        selectedTag: 'Sub A one',
      ),
    );

    await tester.tap(find.text('Provider A'));
    await tester.pumpAndSettle();
    expect(find.text('Sub A one'), findsNothing);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text('Provider A'));
    await tester.pumpAndSettle();
    expect(find.text('Sub A one'), findsOneWidget);
  });

  testWidgets("a subscription's name finds all of its servers", (tester) async {
    await mount(
      tester,
      ProfileData(
        servers: [
          for (var i = 1; i <= 4; i++) server('Mine $i'),
          for (var i = 1; i <= 4; i++) server('SG-0$i', 'a'),
        ],
        subscriptions: [subscription('a', 'Provider A')],
      ),
    );

    await tester.enterText(find.byType(TextField), 'provider');
    await tester.pumpAndSettle();

    expect(find.text('Added manually'), findsNothing);
    expect(find.text('SG-01'), findsOneWidget);
    expect(find.text('SG-04'), findsOneWidget);
  });

  testWidgets('only a subscription heading offers a refresh', (tester) async {
    await mount(
      tester,
      ProfileData(
        servers: [server('Mine'), server('Sub A one', 'a')],
        subscriptions: [subscription('a', 'Provider A')],
      ),
    );

    // One in the app bar for the subscriptions sheet is a different icon.
    expect(find.widgetWithIcon(IconButton, Icons.refresh), findsOneWidget);
  });

  testWidgets('a long subscription keeps its name in view while scrolling through it', (
    tester,
  ) async {
    await mount(
      tester,
      ProfileData(
        servers: [
          server('Mine'),
          for (var i = 0; i < 30; i++) server('Server ${i.toString().padLeft(2, '0')}', 'a'),
        ],
        subscriptions: [subscription('a', 'Provider A')],
      ),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pumpAndSettle();

    // Pinned to the top of the list rather than scrolled away with its first rows.
    final listTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    expect(top(tester, 'Provider A'), inInclusiveRange(listTop, listTop + 24));
  });

  testWidgets('a subscription is removed from its own heading, after asking', (tester) async {
    await mount(
      tester,
      ProfileData(
        servers: [server('Mine'), server('Sub A one', 'a'), server('Sub B one', 'b')],
        subscriptions: [subscription('a', 'Provider A'), subscription('b', 'Provider B')],
      ),
    );

    // One menu per subscription; the hand-added group has none.
    final menus = find.widgetWithIcon(PopupMenuButton<VoidCallback>, Icons.more_vert);
    expect(menus, findsNWidgets(2));

    await tester.tap(menus.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // Cancelling keeps it.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Sub A one'), findsOneWidget);

    await tester.tap(menus.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('Provider A'), findsNothing);
    expect(find.text('Sub A one'), findsNothing);
    expect(find.text('Provider B'), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);
  });
}
