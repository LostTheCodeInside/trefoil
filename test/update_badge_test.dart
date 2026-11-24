import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/app_update.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/app_shell.dart';

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

/// Widget tests answer every HTTP request with a 400; the check runs under this so it
/// reaches the server the test starts.
class _RealHttp extends HttpOverrides {}

/// A waiting update is badged on the Settings destination and named on the About row:
/// the snackbar is gone in seconds, and About is two taps deep.
void main() {
  testWidgets('a waiting update badges Settings and is named on the About row', (tester) async {
    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.write(
          jsonEncode({
            'versionName': '1.1.0',
            'apks': [
              {
                'abi': 'arm64-v8a',
                'versionCode': 2002,
                'url': 'trefoil-1.1.0-arm64-v8a.apk',
                'size': 1000,
                'sha256': 'a' * 64,
              },
            ],
          }),
        );
        await request.response.close();
      });
    });
    addTearDown(() => server.close(force: true));
    final cache = Directory.systemTemp.createTempSync('trefoil-badge');
    addTearDown(() => cache.deleteSync(recursive: true));
    final original = AppUpdater.instance;
    final updater = AppUpdater.instance = AppUpdater(
      platform: _Platform(),
      manifestUrl: Uri.parse('http://127.0.0.1:${server.port}/trefoil/latest.json'),
      cacheDirectory: () async => cache,
    );
    addTearDown(() => AppUpdater.instance = original);

    // Found before the shell is built, the way a locale change rebuilds it.
    await tester.runAsync(() => HttpOverrides.runWithHttpOverrides(updater.check, _RealHttp()));
    expect(updater.stage, UpdateStage.available);

    final dir = Directory.systemTemp.createTempSync('trefoil-badge-profile');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = _Channel();
    addTearDown(channel.close);
    final controller = TunnelController(
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
    await tester.pumpAndSettle();

    Badge settingsBadge() => tester.widget<Badge>(
      find.ancestor(of: find.byIcon(Icons.tune_outlined), matching: find.byType(Badge)),
    );
    expect(settingsBadge().isLabelVisible, isTrue);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Trefoil 1.1.0 is available'), 200);
    expect(find.text('Trefoil 1.1.0 is available'), findsOneWidget);
  });
}
