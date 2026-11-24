import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/app_shell.dart';
import 'package:trefoil/ui/home_screen.dart';

/// Streams that stay quiet, so the shell can be mounted without a platform behind it.
///
/// The real channel raises MissingPluginException the moment the traffic panel
/// subscribes, which has nothing to do with what these tests measure.
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

/// The shell picks its navigation from the width it is given.
///
/// A bottom bar on a tablet or an unfolded foldable spends the short dimension --
/// the one a list needs -- on three destinations, and puts them at the far edge of a
/// two-handed grip. The rail takes the long dimension instead, which is the one
/// there is plenty of.
///
/// The shell shows a spinner until the profile has loaded, so unlike the other
/// screen tests this one has to init() the controller — inside runAsync, because a
/// testWidgets body is a fake-async zone where real disk I/O never completes.
void main() {
  late TunnelController controller;

  Future<void> pumpShell(WidgetTester tester, Size physical) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('trefoil-shell');
    addTearDown(() => dir.deleteSync(recursive: true));

    final channel = _Channel();
    addTearDown(channel.close);
    controller = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.init);

    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump();
  }

  // Every Settings page is pushed over the shell, and a toggle there used to rebuild
  // all three tabs underneath it, none of which anyone could see.
  testWidgets('tabs covered by a page hold still and catch up once', (tester) async {
    await pumpShell(tester, const Size(720, 1560));
    var homeBuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is HomeScreen) homeBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    void change() => controller.notifyListeners();

    change();
    await tester.pump();
    expect(homeBuilds, 1, reason: 'in view, a change is drawn');

    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('page'))));
    await tester.pumpAndSettle();
    homeBuilds = 0;
    for (var i = 0; i < 5; i++) {
      change();
      await tester.pump();
    }
    expect(homeBuilds, 0, reason: 'under a page, changes are only held');

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(homeBuilds, 1, reason: 'back in view, it catches up in one build');
  });

  testWidgets('a phone keeps the bottom bar', (tester) async {
    // 360dp wide at 2x.
    await pumpShell(tester, const Size(720, 1560));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('a tablet gets the rail instead', (tester) async {
    // 800dp wide at 2x, comfortably past the breakpoint.
    await pumpShell(tester, const Size(1600, 2400));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('the breakpoint is inclusive', (tester) async {
    // Exactly 600dp. A device that lands on the boundary has to pick one layout and
    // stay there; landing between them is how a rebuild loop starts.
    await pumpShell(tester, Size(railBreakpoint * 2, 2000));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('both layouts offer the same three destinations', (tester) async {
    await pumpShell(tester, const Size(720, 1560));
    for (final label in ['Connect', 'Servers', 'Settings']) {
      expect(find.text(label), findsWidgets, reason: 'bottom bar is missing $label');
    }

    await pumpShell(tester, const Size(1600, 2400));
    for (final label in ['Connect', 'Servers', 'Settings']) {
      expect(find.text(label), findsWidgets, reason: 'rail is missing $label');
    }
  });

  testWidgets('rotating a phone into landscape swaps the bar for the rail', (tester) async {
    // The case the breakpoint exists for beyond tablets: in landscape the height is
    // what runs out first, and the bottom bar is what is taking it.
    await pumpShell(tester, const Size(720, 1560));
    expect(find.byType(NavigationBar), findsOneWidget);

    tester.view.physicalSize = const Size(1560, 720);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
