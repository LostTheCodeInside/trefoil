import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/app_shell.dart';

void main() {
  testWidgets('shows the empty state when no servers are configured', (tester) async {
    // The controller is used without init(): there is no platform channel under
    // `flutter test`, and the UI must render regardless.
    final controller = TunnelController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: MaterialApp(
          // The shell reads localized strings, so the delegates have to be present
          // even for a test that only checks which state it lands in.
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AppShell(),
        ),
      ),
    );

    // isLoading is true until init() completes, so the shell shows a spinner.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  group('formatBytes', () {
    test('scales units and keeps whole numbers readable', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1024 * 1024 * 3), '3.0 MB');
    });

    test('never renders a negative size', () {
      expect(formatBytes(-1), '0 B');
    });
  });

  group('localization', () {
    // Every language file, not just the pair that happened to exist first.
    final files = Directory('lib/l10n')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.arb'))
        .toList();

    Map<String, Object?> read(File file) =>
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

    test('there are language files to check', () {
      expect(files.length, greaterThanOrEqualTo(2));
    });

    test('every language defines exactly the same keys as English', () {
      // A key present in one file and not another shows up as an English string in
      // the middle of translated UI, which no test of the widgets would catch.
      final template = read(File('lib/l10n/app_en.arb'));
      final expected = template.keys.where((k) => !k.startsWith('@')).toSet();

      for (final file in files) {
        final keys = read(file).keys.where((k) => !k.startsWith('@')).toSet();
        expect(keys, expected, reason: 'keys differ in ${file.path}');
      }
    });

    test('placeholders survive translation in every language', () {
      // A placeholder dropped in translation throws at runtime, not at build time,
      // and in a language the reviewer probably cannot read.
      final template = read(File('lib/l10n/app_en.arb'));
      final pattern = RegExp(r'\{(\w+)\}');

      for (final file in files) {
        final translated = read(file);
        for (final key in template.keys.where((k) => !k.startsWith('@'))) {
          final expected = pattern.allMatches(template[key]! as String).map((m) => m[1]).toSet();
          final actual = pattern.allMatches(translated[key]! as String).map((m) => m[1]).toSet();
          expect(actual, expected, reason: 'placeholders differ for "$key" in ${file.path}');
        }
      }
    });

    test('no language was left as a copy of English', () {
      // A file that is byte-identical to the template is an untranslated stub, which
      // looks finished in the picker and is not.
      final template = read(File('lib/l10n/app_en.arb'));
      for (final file in files) {
        if (file.path.endsWith('app_en.arb')) continue;
        final translated = read(file);
        final identical = template.keys
            .where((k) => !k.startsWith('@'))
            .where((k) => template[k] == translated[k])
            .length;
        expect(
          identical,
          lessThan(template.length ~/ 2),
          reason: '${file.path} looks untranslated',
        );
      }
    });
  });
}
