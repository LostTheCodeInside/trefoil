import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/app_icons.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/per_app_screen.dart';

/// The per-app list draws one icon per row, and the list rebuilds on every keystroke
/// in its search box. What is under test is that those two facts do not multiply.
void main() {
  Uint8List bytes(int b) => Uint8List.fromList([b]);

  group('the icon cache', () {
    test('asks the platform once per app, however often it is asked', () async {
      var calls = 0;
      final icons = AppIcons(
        fetch: (packageName) async {
          calls++;
          return bytes(1);
        },
      );
      // Three rows wanting the same icon at once, then a fourth after it arrived.
      await Future.wait([icons.load('a'), icons.load('a'), icons.load('a')]);
      expect(await icons.load('a'), isNotNull);
      expect(calls, 1);
    });

    test('bytes already in hand are handed over without a wait', () async {
      final icons = AppIcons(fetch: (packageName) async => bytes(9));
      expect(icons.cached('a'), isNull);
      await icons.load('a');
      expect(icons.cached('a'), isNotNull);
    });

    test('an app with no icon is remembered as having none', () async {
      var calls = 0;
      final icons = AppIcons(
        fetch: (packageName) async {
          calls++;
          return null;
        },
      );
      expect(await icons.load('a'), isNull);
      expect(await icons.load('a'), isNull);
      expect(calls, 1);
    });

    // A channel that was not there to answer is not the same as an app without an
    // icon. Remembering the first would leave a placeholder for the rest of the
    // session over a failure that has already passed.
    test('a fetch that threw is tried again, not remembered', () async {
      var calls = 0;
      final icons = AppIcons(
        fetch: (packageName) async {
          calls++;
          if (calls == 1) throw Exception('no channel');
          return bytes(7);
        },
      );
      expect(await icons.load('a'), isNull);
      expect(await icons.load('a'), isNotNull);
      expect(calls, 2);
    });

    // A full app drawer is a few hundred icons, and this holds them decoded.
    test('holds only so many', () async {
      final icons = AppIcons(capacity: 2, fetch: (packageName) async => bytes(1));
      for (final packageName in ['a', 'b', 'c']) {
        await icons.load(packageName);
      }
      expect(icons.cached('a'), isNull);
      expect(icons.cached('c'), isNotNull);
    });
  });

  group('the per-app screen', () {
    late Directory dir;
    late List<String> asked;
    late List<String> packages;

    const control = MethodChannel('trefoil/control');

    // Package names are unique per test, because the icon cache is the app's one
    // instance and a name another test already asked for would be served from it —
    // which would quietly turn the count below into zero.
    var run = 0;

    setUp(() {
      run++;
      dir = Directory.systemTemp.createTempSync('trefoil-per-app');
      asked = [];
      packages = ['test.alpha$run', 'test.beta$run'];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        control,
        (call) async {
          switch (call.method) {
            case 'installedApps':
              return [
                for (final (index, name) in ['alpha', 'beta'].indexed)
                  {'packageName': packages[index], 'label': name, 'system': false},
                // A system app with no launcher entry, the way Play Services is.
                {
                  'packageName': 'test.services$run',
                  'label': 'services',
                  'system': true,
                  'background': true,
                },
              ];
            case 'appIcon':
              asked.add(call.arguments as String);
              // No icon, so the row keeps its placeholder — which is also what
              // spares this test the engine's image decoder.
              return null;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        control,
        null,
      );
      dir.deleteSync(recursive: true);
    });

    // Chosen apps sort to the top so they can be found at all, but the order is
    // settled when the screen opens: if it followed the ticks, the row you just
    // tapped would leap to the top and take the next one out from under your finger.
    Future<void> pumpPerApp(WidgetTester tester, Directory dir) async {
      tester.view.physicalSize = const Size(1080, 2100);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final controller = TunnelController(store: ProfileStore(directory: dir));
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        TunnelScope(
          controller: controller,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PerAppScreen(),
          ),
        ),
      );
    }

    List<String> labelsInOrder(WidgetTester tester) => tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .map((tile) => ((tile.title as Text).data)!)
        .toList();

    testWidgets('ticking an app does not move it', (tester) async {
      await pumpPerApp(tester, dir);
      await tester.tap(find.text('Only these'));
      await tester.pumpAndSettle();
      expect(labelsInOrder(tester), ['alpha', 'beta']);

      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      expect(labelsInOrder(tester), ['alpha', 'beta']);
      expect(find.text('Selected: 1'), findsOneWidget);
    });

    // Hidden by default, because there are hundreds — but reachable, because a few of
    // them carry real traffic and could otherwise never be routed at all.
    testWidgets('background system apps are listed only when asked for', (tester) async {
      await pumpPerApp(tester, dir);
      await tester.tap(find.text('Only these'));
      await tester.pumpAndSettle();
      expect(labelsInOrder(tester), ['alpha', 'beta']);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show system apps'));
      await tester.pumpAndSettle();
      expect(labelsInOrder(tester), ['alpha', 'beta', 'services']);

      // Chosen, it stays visible with the switch off again: a selection the list
      // hides is one nobody can see or undo.
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show system apps'));
      await tester.pumpAndSettle();
      expect(labelsInOrder(tester), contains('services'));
    });

    testWidgets('draws an icon slot per app and asks for each one once', (tester) async {
      await pumpPerApp(tester, dir);
      // The list only exists once the mode is something other than "All".
      await tester.tap(find.text('Only these'));
      await tester.pumpAndSettle();

      expect(find.text('alpha'), findsOneWidget);
      expect(find.byIcon(Icons.apps_outlined), findsNWidgets(2));
      expect(asked, unorderedEquals(packages));

      // Typing rebuilds every row. The icons must come from the cache, not the
      // channel: a call per row per keystroke is what this guards against.
      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pumpAndSettle();
      expect(find.text('beta'), findsNothing);
      expect(asked, unorderedEquals(packages));
    });
  });
}
