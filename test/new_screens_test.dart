import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/routing_screen.dart';
import 'package:trefoil/ui/settings_multiplex_screen.dart';
import 'package:trefoil/ui/settings_screen.dart';

/// Layout, on a real phone's geometry, for the screens this change adds or reworks.
///
/// The analyzer cannot see an overflow and neither can a config test: a row whose
/// text runs long simply renders a yellow-and-black bar on the device. Pumping each
/// screen is what turns that into a failure.
///
/// Nothing here writes a setting. A `testWidgets` body runs in a fake-async zone
/// where real disk I/O never completes, so awaiting a save from inside one hangs
/// instead of failing — which is why the controller is left un-init()ed and the
/// screens are checked against their defaults.
void main() {
  Future<void> pumpWith(WidgetTester tester, Widget home, {Locale? locale}) async {
    tester.view.physicalSize = const Size(1080, 2100);
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding = const FakeViewPadding(bottom: 144, top: 90);
    addTearDown(tester.view.reset);

    final controller = TunnelController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the multiplex screen lays out', (tester) async {
    await pumpWith(tester, const MultiplexSettingsScreen());
    expect(find.text('Enable multiplex'), findsOneWidget);
    // The rows below the switch stay on screen while it is off, greyed rather than
    // hidden: a row that disappears takes the explanation with it.
    expect(find.text('Streams per connection'), findsOneWidget);
    // The scope note is what stops someone turning this on for a QUIC server and
    // wondering why nothing changed.
    expect(find.textContaining('VMess'), findsOneWidget);

    // Padding sits below the fold on a 700dp-tall screen, so it has to be scrolled
    // to rather than found: the list builds lazily, and asserting without scrolling
    // would be asserting that the screen is short rather than that the row exists.
    await tester.scrollUntilVisible(find.text('Padding'), 100, scrollable: find.byType(Scrollable));
    expect(find.text('Padding'), findsOneWidget);
  });

  testWidgets('the settings hub shows the multiplex row', (tester) async {
    await pumpWith(tester, const SettingsScreen());
    expect(find.text('Multiplex'), findsOneWidget);
  });

  testWidgets('every rule kind is offered, in the longest of the shipped languages', (
    tester,
  ) async {
    await pumpWith(tester, const RoutingScreen(), locale: const Locale('ru'));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<RuleMatch>));
    await tester.pumpAndSettle();

    // Every kind has to be reachable, not only the ones that happen to fit.
    for (final match in RuleMatch.values) {
      expect(
        find.byWidgetPredicate(
          (widget) => widget is DropdownMenuItem<RuleMatch> && widget.value == match,
        ),
        findsWidgets,
        reason: '${match.name} is missing from the picker',
      );
    }
  });

  // The icon is the only thing on this screen that says a download is happening, so
  // it has to be the kind of icon that can turn. A plain Icon here would be a silent
  // regression: nothing else about the screen would look wrong.
  testWidgets('the update-lists action is built to turn', (tester) async {
    await pumpWith(tester, const RoutingScreen());
    final button = find.ancestor(of: find.byIcon(Icons.refresh), matching: find.byType(IconButton));
    expect(button, findsOneWidget);
    expect(find.descendant(of: button, matching: find.byType(RotationTransition)), findsOneWidget);
    // And it says which of the two states it is in, for the case where the turning
    // itself is missed.
    expect(tester.widget<IconButton>(button).tooltip, 'Update lists');
  });

  testWidgets('a closed-set field offers a picker instead of a text box', (tester) async {
    await pumpWith(tester, const RoutingScreen());
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Free text to begin with, since domain suffix is the default.
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<RuleMatch>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Network').last);
    await tester.pumpAndSettle();

    // `protocol: htp` is valid JSON that matches nothing, and nothing about the
    // result would say why — so these fields get no text box at all.
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
  });

  testWidgets('the sheet refuses a value the core would reject', (tester) async {
    await pumpWith(tester, const RoutingScreen());
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<RuleMatch>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Port').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '99999');
    await tester.tap(find.widgetWithText(FilledButton, 'Add rule'));
    await tester.pumpAndSettle();

    // Still open, and now saying why. Accepting it would have produced a rule that
    // sing-box rejects the whole config over.
    expect(find.text('That value is not usable'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add rule'), findsOneWidget);
  });
}
