import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/routing_screen.dart';

/// Layout that has to follow the reading direction, checked in Arabic.
///
/// The app ships `ar` and `fa`. An absolute `right` or `centerRight` looks correct
/// in every locale that reads left to right and pins the widget to the wrong edge in
/// the two that do not — a swipe-to-delete background whose icon sits at the edge
/// the row is moving away from, so the user swipes and sees nothing appear.
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

void main() {
  testWidgets('the swipe-to-delete icon follows the reading direction', (tester) async {
    tester.view.physicalSize = const Size(1080, 2100);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('trefoil-rtl');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = _Channel();
    addTearDown(channel.close);
    final controller = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    addTearDown(controller.dispose);

    // Seeded on disk rather than added through the controller: addRule persists, and
    // a persist awaited from a testWidgets body deadlocks against the fake clock.
    await tester.runAsync(() async {
      await ProfileStore(directory: dir).save(
        ProfileData(
          settings: ConfigBuilder(
            routing: RoutingSettings.defaults.copyWith(
              rules: const [
                RoutingRule(
                  match: RuleMatch.domain,
                  value: 'example.test',
                  action: RuleAction.block,
                ),
              ],
            ),
          ),
        ),
      );
      await controller.init();
    });
    expect(controller.routing.rules, hasLength(1));

    Future<void> pump(Locale locale) async {
      await tester.pumpWidget(
        TunnelScope(
          controller: controller,
          child: MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const RoutingScreen(),
          ),
        ),
      );
      await tester.pump();
      // The rule list sits below every preset, so on a phone it is off-screen and
      // the ListView has not built it yet.
      await tester.scrollUntilVisible(find.byType(Dismissible), 200);
      await tester.pumpAndSettle();
    }

    // Dismissible builds its background only while a drag is in flight, so the
    // gesture is held open rather than completed -- releasing it would remove the
    // rule and take the thing being measured with it.
    Future<double> iconCentreDuringDrag(double dx) async {
      final row = find.byType(Dismissible).first;
      final gesture = await tester.startGesture(tester.getCenter(row));
      // Moved in steps: one jump can be taken for a fling, and the gesture arena
      // needs a few frames to hand the drag to the Dismissible rather than the list.
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(Offset(dx / 4, 0));
        await tester.pump();
      }

      final icon = find.descendant(
        of: find.byType(Dismissible),
        matching: find.byIcon(Icons.delete_outline),
      );
      expect(icon, findsOneWidget, reason: 'the swipe revealed no delete background');
      final centre = tester.getCenter(icon).dx;

      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(Offset(-dx / 4, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      return centre;
    }

    await pump(const Locale('en'));
    final width = tester.getSize(find.byType(Dismissible).first).width;
    expect(width, greaterThan(0));

    // endToStart: dragging away from the trailing edge, which is the left in English.
    final ltrCentre = await iconCentreDuringDrag(-120);
    expect(
      ltrCentre,
      greaterThan(width / 2),
      reason: 'in English the icon belongs at the right, the edge the row leaves',
    );

    await pump(const Locale('ar'));
    // The same gesture mirrored: in Arabic the trailing edge is the left one.
    final rtlCentre = await iconCentreDuringDrag(120);
    expect(
      rtlCentre,
      lessThan(width / 2),
      reason: 'in Arabic it has to mirror; Alignment.centerRight would not',
    );
  });
}
