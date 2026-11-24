import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/home_screen.dart';

void main() {
  testWidgets('with no servers the connect button explains itself', (tester) async {
    // The button is disabled without a server, so tapping it used to do nothing at
    // all -- no error, no hint, nothing to act on. That is what this guards.
    var addRequested = false;
    final controller = TunnelController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomeScreen(onAddServer: () => addRequested = true),
        ),
      ),
    );
    await tester.pump();

    expect(controller.servers, isEmpty);
    await tester.tap(find.byType(InkWell).first);
    // Long enough for the snackbar to finish sliding in; tapping mid-animation
    // lands outside the action's hit box.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.noServersYet), findsWidgets);

    await tester.tap(find.text(l10n.actionAddServer));
    await tester.pump();
    expect(addRequested, isTrue, reason: 'the snackbar action should open the server list');
  });
}
