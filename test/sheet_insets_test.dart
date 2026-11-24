import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/routing_screen.dart';
import 'package:trefoil/ui/servers_screen.dart';

/// Bottom sheets are laid out edge to edge from Android 15 on, so their own padding
/// is the only thing keeping a submit button above the navigation bar. Asserting on
/// geometry rather than on a golden keeps this meaningful across Flutter versions.
void main() {
  const navBarPhysical = 144.0;
  const dpr = 3.0;
  const screenPhysical = Size(1080, 2100);

  Future<void> pumpWith(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = screenPhysical;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(bottom: navBarPhysical, top: 90);
    addTearDown(tester.view.reset);

    final controller = TunnelController();
    addTearDown(controller.dispose);

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
    await tester.pump();
  }

  final safeBottom = screenPhysical.height / dpr - navBarPhysical / dpr;

  testWidgets('the add-rule sheet keeps its button above the navigation bar', (tester) async {
    await pumpWith(tester, const RoutingScreen());
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final button = tester.getRect(find.widgetWithText(FilledButton, 'Add rule').last);
    expect(
      button.bottom,
      lessThanOrEqualTo(safeBottom),
      reason: 'the submit button is under the navigation bar',
    );
  });

  testWidgets('the add-server sheet keeps its button above the navigation bar', (tester) async {
    await pumpWith(tester, const ServersScreen());
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final button = tester.getRect(find.byType(FilledButton).first);
    expect(button.bottom, lessThanOrEqualTo(safeBottom));
  });
}
