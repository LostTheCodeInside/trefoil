import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/app_update.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/ui/about_screen.dart';

class _Platform implements UpdatePlatform {
  @override
  Future<InstalledBuild> installed() async =>
      const InstalledBuild(versionName: '1.0.0', versionCode: 2001, abis: ['arm64-v8a']);

  @override
  Future<void> install(File apk, AppUpdate update) async {}

  @override
  Future<void> openInstallSettings() async {}

  @override
  Stream<InstallReport> get reports => const Stream.empty();
}

/// Widget tests answer every HTTP request with a 400. The update check is run under
/// this instead, so it reaches the real server the test starts.
class _RealHttp extends HttpOverrides {}

void main() {
  late HttpServer server;
  late AppUpdater updater;

  Future<void> mount(WidgetTester tester, {required bool published}) async {
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (published && request.uri.path == '/trefoil/latest.json') {
          request.response.write(
            jsonEncode({
              'versionName': '1.1.0',
              'notes': '- Servers are grouped by subscription.',
              'apks': [
                {
                  'abi': 'arm64-v8a',
                  'versionCode': 2002,
                  'url': 'trefoil-1.1.0-arm64-v8a.apk',
                  'size': 101 * 1024 * 1024,
                  'sha256': 'a' * 64,
                },
              ],
            }),
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
    });
    addTearDown(() => server.close(force: true));
    final cache = Directory.systemTemp.createTempSync('trefoil-about');
    addTearDown(() => cache.deleteSync(recursive: true));
    updater = AppUpdater(
      platform: _Platform(),
      manifestUrl: Uri.parse('http://127.0.0.1:${server.port}/trefoil/latest.json'),
      cacheDirectory: () async => cache,
    );
    addTearDown(updater.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AboutScreen(updater: updater),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> check(WidgetTester tester) async {
    await tester.runAsync(() => HttpOverrides.runWithHttpOverrides(updater.check, _RealHttp()));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the installed version before anything is asked', (tester) async {
    await mount(tester, published: true);

    expect(find.text('Version 1.0.0'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Check'), findsOneWidget);
  });

  testWidgets('a newer build is offered with its size and what changed', (tester) async {
    await mount(tester, published: true);
    await check(tester);

    expect(find.text('Version 1.1.0 is available · 101 MB'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);
    expect(find.text("What's new in 1.1.0"), findsOneWidget);
    expect(find.text('- Servers are grouped by subscription.'), findsOneWidget);
  });

  testWidgets('a failed check says why and offers another go', (tester) async {
    await mount(tester, published: false);
    await check(tester);

    expect(find.text('The update server answered HTTP 404'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Try again'), findsOneWidget);
  });
}
