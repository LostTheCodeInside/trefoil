import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/l10n/app_localizations.dart';

void main() {
  // A guard against the translation silently falling back to English, which is what
  // happens when a key is missing and is invisible in a screenshot of a screen you
  // do not read.
  testWidgets('Indonesian actually renders, with placeholders substituted', (tester) async {
    late AppLocalizations id;
    late AppLocalizations en;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('id'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            id = AppLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            en = AppLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(id.stateConnected, 'Tersambung');
    expect(en.stateConnected, 'Connected');
    expect(id.searchServers(42), contains('42'));
    expect(id.quotaExpiresIn(3), contains('3'));
    expect(id.rulesSummary(2, 5), allOf(contains('2'), contains('5')));
  });

  testWidgets('right-to-left languages actually lay out right-to-left', (tester) async {
    // Adding an .arb file is not enough on its own: the direction comes from the
    // Flutter delegates, and a misconfigured MaterialApp silently renders Arabic
    // left-to-right, which looks merely odd rather than broken.
    for (final expected in <String, TextDirection>{
      'en': TextDirection.ltr,
      'id': TextDirection.ltr,
      'ar': TextDirection.rtl,
      'fa': TextDirection.rtl,
    }.entries) {
      late TextDirection actual;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(expected.key),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              actual = Directionality.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      expect(actual, expected.value, reason: 'wrong direction for ${expected.key}');
    }
  });

  testWidgets('every advertised language resolves to itself, not to English', (tester) async {
    // A locale listed in the picker but missing a delegate falls back silently, so
    // the language appears selectable and changes nothing.
    for (final locale in AppLocalizations.supportedLocales) {
      late AppLocalizations resolved;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              resolved = AppLocalizations.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      expect(resolved.localeName, locale.languageCode);
    }
  });
}
