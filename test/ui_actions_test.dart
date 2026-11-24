import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/action_error.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/profile/usage_history.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/app_shell.dart';
import 'package:trefoil/ui/backup_screen.dart';
import 'package:trefoil/ui/connections_screen.dart';
import 'package:trefoil/ui/routing_screen.dart';
import 'package:trefoil/ui/servers_screen.dart';
import 'package:trefoil/ui/settings_general_screen.dart';
import 'package:trefoil/ui/settings_widgets.dart';
import 'package:trefoil/ui/usage_screen.dart';

/// Answers without touching the disk, which a widget test cannot wait for.
class _Controller extends TunnelController {
  bool pending = false;
  int reconnects = 0;
  final locales = <String?>[];
  final restored = <String>[];

  /// What the next added link comes back with; null for one that is taken.
  ActionError? refusal;
  ActionError? _shown;

  List<RoutingRule> rules = [];

  void changed() => notifyListeners();

  @override
  bool get isLoading => false;

  @override
  bool get needsReconnect => pending;

  @override
  Future<void> reconnect({Duration stopTimeout = const Duration(seconds: 10)}) async =>
      reconnects++;

  @override
  Future<void> setLocale(String? code) async => locales.add(code);

  @override
  ActionError? get lastActionError => _shown;

  @override
  void clearActionError() => _shown = null;

  void fail(ActionError error) {
    _shown = error;
    notifyListeners();
  }

  @override
  ActionError? takeActionError() {
    final error = refusal;
    refusal = null;
    return error;
  }

  @override
  Future<bool> addFromLink(String link) async => refusal == null;

  @override
  Future<void> importBackup(String encoded, String password) async => restored.add(encoded);

  @override
  RoutingSettings get routing => RoutingSettings(rules: rules);

  @override
  Future<void> removeRuleAt(int index) async {
    rules = [...rules]..removeAt(index);
    notifyListeners();
  }
}

void main() {
  late _Controller controller;
  late Map<String, Object? Function(Object? argument)> control;
  late List<String> called;

  setUp(() {
    controller = _Controller();
    control = {};
    called = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('trefoil/control'), (call) async {
      called.add(call.method);
      return control[call.method]?.call(call.arguments);
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('trefoil/control'), null);
    messenger.setMockStreamHandler(const EventChannel('trefoil/connections'), null);
    controller.dispose();
  });

  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> pump(WidgetTester tester, Widget home, {String locale = 'en'}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
    await tester.pump();
  }

  group('the language dialog', () {
    Future<void> open(WidgetTester tester, String? current) async {
      await pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickLanguage(context, current),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('leaves the language alone when it is backed out of', (tester) async {
      await open(tester, 'id');
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(controller.locales, isEmpty);
    });

    testWidgets('can still hand it back to the device', (tester) async {
      await open(tester, 'id');
      await tester.tap(find.text(l10n.languageSystem));
      await tester.pumpAndSettle();
      expect(controller.locales, [null]);
    });
  });

  group('the add sheet', () {
    Future<void> submit(WidgetTester tester) async {
      await pump(tester, const ServersScreen());
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'vless://nonsense');
      await tester.pump();
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
    }

    testWidgets('stays, with what was typed, when the link is refused', (tester) async {
      controller.refusal = const ActionError(ActionErrorKind.notALink);
      await submit(tester);
      expect(find.text('vless://nonsense'), findsOneWidget);
      expect(find.text(l10n.errorNotALink), findsOneWidget);

      // Corrected, the complaint goes: it was about what is no longer there.
      await tester.enterText(find.byType(TextField).first, 'vless://better');
      await tester.pump();
      expect(find.text(l10n.errorNotALink), findsNothing);
    });

    testWidgets('closes once the link is taken', (tester) async {
      await submit(tester);
      expect(find.text('vless://nonsense'), findsNothing);
    });
  });

  group('a setting that needs a reconnect', () {
    testWidgets('says so for as long as it does', (tester) async {
      await pump(tester, const AppShell());
      expect(find.text(l10n.settingsChangedReconnect), findsNothing);

      controller
        ..pending = true
        ..changed();
      await tester.pumpAndSettle();
      expect(find.text(l10n.settingsChangedReconnect), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
      expect(find.text(l10n.settingsChangedReconnect), findsOneWidget);

      await tester.tap(find.text(l10n.actionReconnect));
      expect(controller.reconnects, 1);

      controller
        ..pending = false
        ..changed();
      await tester.pumpAndSettle();
      expect(find.text(l10n.settingsChangedReconnect), findsNothing);
    });

    testWidgets('does not hold back an error', (tester) async {
      await pump(tester, const AppShell());
      controller
        ..pending = true
        ..changed();
      await tester.pumpAndSettle();
      controller.fail(const ActionError(ActionErrorKind.notALink));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l10n.errorNotALink), findsOneWidget);
    });
  });

  group('the connections screen', () {
    Future<void> open(WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockStreamHandler(
        const EventChannel('trefoil/connections'),
        MockStreamHandler.inline(
          onListen: (_, events) => events.success([
            {
              'id': 'c1',
              'host': 'example.com',
              'destination': '203.0.113.9:443',
              'outbound': 'proxy',
            },
          ]),
        ),
      );
      await pump(tester, const ConnectionsScreen());
      await tester.pump();
      called.clear();
    }

    testWidgets('asks before it ends every connection', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip(l10n.connectionsCloseAll));
      await tester.pumpAndSettle();
      expect(called, isEmpty);
      await tester.tap(find.text(l10n.actionCancel));
      await tester.pumpAndSettle();
      expect(called, isEmpty);

      await tester.tap(find.byTooltip(l10n.connectionsCloseAll));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, l10n.connectionsCloseAll));
      await tester.pumpAndSettle();
      expect(called, ['closeConnections']);
      expect(find.text(l10n.connectionsClosed), findsOneWidget);
    });

    testWidgets('ends a single one by its own button', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip(l10n.connectionClose));
      await tester.pumpAndSettle();
      expect(called, ['closeConnection']);
    });
  });

  testWidgets('a switch that could not be stored goes back', (tester) async {
    control['setAutoStart'] = (_) => throw PlatformException(code: 'io');
    await pump(tester, const GeneralSettingsScreen());
    await tester.pumpAndSettle();
    final row = find.widgetWithText(SwitchListTile, l10n.connectAfterRestart);
    await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<SwitchListTile>(row).value, isFalse);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(called, contains('setAutoStart'));
    expect(tester.widget<SwitchListTile>(row).value, isFalse);
    expect(find.text(l10n.settingNotSaved), findsOneWidget);
  });

  group('restoring a backup', () {
    Future<void> ask(WidgetTester tester) async {
      await pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const BackupScreen())),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.backupTabRestore));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'VEhSMw==');
      await tester.enterText(find.byType(TextField).at(1), 'password1');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, l10n.backupRestore));
      await tester.pumpAndSettle();
      expect(find.text(l10n.backupReplaceTitle), findsOneWidget);
      expect(controller.restored, isEmpty);
    }

    testWidgets('does nothing when it is called off', (tester) async {
      await ask(tester);
      await tester.tap(find.text(l10n.actionCancel));
      await tester.pumpAndSettle();
      expect(controller.restored, isEmpty);
    });

    testWidgets('goes ahead once it is agreed to', (tester) async {
      await ask(tester);
      await tester.tap(find.widgetWithText(FilledButton, l10n.backupRestore).last);
      await tester.pumpAndSettle();
      expect(controller.restored, ['VEhSMw==']);
    });
  });

  group('a routing rule', () {
    const rule = RoutingRule(
      match: RuleMatch.domainSuffix,
      value: 'example.com',
      action: RuleAction.direct,
    );

    testWidgets('can be removed from its own sheet', (tester) async {
      controller.rules = const [rule];
      await pump(tester, const RoutingScreen());
      await tester.scrollUntilVisible(
        find.text('example.com'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final edit = find.byTooltip(l10n.editRule);
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.actionRemove));
      await tester.pumpAndSettle();
      expect(controller.rules, isEmpty);
      expect(find.text(l10n.actionUndo), findsOneWidget);
    });

    for (final (locale, arrow) in const [('en', '→'), ('ar', '←'), ('fa', '←')]) {
      testWidgets('points the way $locale is read', (tester) async {
        controller.rules = const [rule];
        await pump(tester, const RoutingScreen(), locale: locale);
        await tester.scrollUntilVisible(
          find.text('example.com'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.textContaining(arrow), findsWidgets);
      });
    }
  });

  testWidgets('the days of the usage chart can be told apart by ear', (tester) async {
    final handle = tester.ensureSemantics();
    final days = [
      DailyUsage(date: DateTime(2026, 11, 22), upload: 1024, download: 1024),
      DailyUsage(date: DateTime(2026, 11, 23), upload: 0, download: 1024),
    ];
    await pump(
      tester,
      Scaffold(
        body: UsageChart(days: days, selected: days.last, onSelect: (_) {}),
      ),
    );
    expect(find.bySemanticsLabel('Nov 22, 2.0 KB'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Nov 23, 1.0 KB')),
      isSemantics(isButton: true, isSelected: true, hasTapAction: true),
    );
    handle.dispose();
  });
}
