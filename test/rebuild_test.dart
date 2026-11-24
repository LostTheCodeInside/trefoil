import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/loopback_auth.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/core/tunnel_status.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/home_screen.dart';

/// A channel whose streams the test drives, standing in for the native side.
class _FakeChannel extends TunnelChannel {
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

  /// What the native side reports at launch: by default, nothing running.
  TunnelStatus launchStatus = TunnelStatus.disconnected;

  /// The config generation the native side holds, as [configVersion] reports it.
  int heldConfigVersion = 0;

  @override
  Future<TunnelStatus> currentStatus() async => launchStatus;

  @override
  Future<int> configVersion() async => heldConfigVersion;

  /// Every start and stop, in order. The platform side is fire-and-forget, so the
  /// order and the timing of these calls is the whole of what the app controls.
  final calls = <String>[];

  @override
  Future<bool> prepare() async => true;

  /// What the last start handed the native side, for tests that check the parts
  /// agree with each other.
  ({String config, String? xrayConfig, String? amneziaConfig, LoopbackAuth? amneziaSocks})?
  lastStart;

  @override
  Future<void> start({
    required String config,
    required String profileName,
    String? xrayConfig,
    String? amneziaConfig,
    LoopbackAuth? amneziaSocks,
    String proxyLabel = 'Proxy',
    String directLabel = 'Direct',
    String groupName = '',
  }) async {
    calls.add('start');
    lastStart = (
      config: config,
      xrayConfig: xrayConfig,
      amneziaConfig: amneziaConfig,
      amneziaSocks: amneziaSocks,
    );
  }

  @override
  Future<void> stop() async => calls.add('stop');

  /// Every selection the app ordered, as (group, outbound).
  final selections = <(String, String)>[];

  @override
  Future<void> selectOutbound({required String group, required String outbound}) async {
    selections.add((group, outbound));
  }

  void tick(TunnelStatus value) => _status.add(value);
  void log(String message) => _logs.add([CoreLogEntry(level: 5, message: message)]);
  void split(TrafficSplit value) => _traffic.add(value);

  /// One selector group holding one server, which is what the core publishes.
  void group({required String tag, required int delayMs, required int testedAt}) => _groups.add([
    OutboundGroup(
      tag: 'proxy',
      type: 'selector',
      selected: tag,
      selectable: true,
      items: [OutboundItem(tag: tag, type: 'vless', delayMs: delayMs, testedAt: testedAt)],
    ),
  ]);

  Future<void> close() async {
    await _status.close();
    await _logs.close();
    await _groups.close();
    await _traffic.close();
  }
}

void main() {
  late Directory dir;
  late _FakeChannel channel;
  late TunnelController controller;

  /// How many times the controller told the whole tree to rebuild. Everything that
  /// reads state through TunnelScope rebuilds once per count.
  late int Function() notifications;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trefoil-rebuild');
    channel = _FakeChannel();
    controller = TunnelController(
      channel: channel,
      store: ProfileStore(directory: dir),
    );
    await controller.init();
    var count = 0;
    controller.addListener(() => count++);
    notifications = () => count;
  });

  tearDown(() async {
    controller.dispose();
    await channel.close();
    dir.deleteSync(recursive: true);
  });

  /// Counts rebuilds of the widget that sits directly under the app's notifier.
  Future<int Function()> mount(WidgetTester tester) async {
    var builds = 0;
    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: ValueListenableBuilder<Locale?>(
          valueListenable: controller.localeListenable,
          builder: (context, locale, _) {
            builds++;
            return MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: locale,
              home: HomeScreen(onAddServer: () {}),
            );
          },
        ),
      ),
    );
    await tester.pump();
    return () => builds;
  }

  const connected = TunnelStatus(stage: TunnelStage.started, trafficAvailable: true);

  /// A stream event is delivered in a microtask, so the first pump renders a frame
  /// the controller has not seen yet. Without the second, a test that counts
  /// rebuilds passes because nothing arrived rather than because nothing rebuilt.
  Future<void> deliver(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a traffic tick does not rebuild the app above it', (tester) async {
    final builds = await mount(tester);
    channel.tick(connected);
    await deliver(tester);
    final settled = builds();
    final before = notifications();

    // Sixty seconds of a live tunnel. Every one of these used to rebuild
    // MaterialApp, and with it every route under it.
    for (var i = 1; i <= 60; i++) {
      channel.tick(
        TunnelStatus(
          stage: TunnelStage.started,
          trafficAvailable: true,
          downlink: i * 1000,
          downlinkTotal: i * 60000,
        ),
      );
      await deliver(tester);
    }

    // The ticks did arrive -- otherwise this test would pass by doing nothing.
    expect(controller.status.downlink, 60000);
    expect(builds(), settled, reason: 'counters must not rebuild the app shell');
    expect(notifications(), before, reason: 'counters must not notify the tree');
  });

  testWidgets('the counters themselves do keep up', (tester) async {
    await mount(tester);
    channel.tick(connected);
    await deliver(tester);

    channel.tick(
      const TunnelStatus(stage: TunnelStage.started, trafficAvailable: true, downlink: 2048),
    );
    await deliver(tester);
    // The panel is the one thing that must redraw -- the split is only correct if
    // the reader still sees live numbers.
    expect(find.text('2.0 KB/s'), findsOneWidget);
  });

  testWidgets('log lines do not rebuild the app either', (tester) async {
    final builds = await mount(tester);
    final settled = builds();
    final before = notifications();
    // A burst like the one a tunnel produces while coming up.
    for (var i = 0; i < 200; i++) {
      channel.log('line $i');
      await deliver(tester);
    }
    expect(controller.logs, hasLength(200));
    expect(builds(), settled);
    expect(notifications(), before, reason: 'log lines must not notify the tree');
  });

  testWidgets('a real state change still rebuilds', (tester) async {
    // The counterpart to the tests above: if nothing rebuilt, the split would be
    // "correct" and useless.
    await mount(tester);
    channel.tick(connected);
    await deliver(tester);
    expect(find.text('Connected'), findsOneWidget);

    channel.tick(const TunnelStatus(stage: TunnelStage.stopped, error: 'gone'));
    await deliver(tester);
    expect(find.text('gone'), findsOneWidget);
  });

  testWidgets('the speed meter shows the proxy/direct split', (tester) async {
    await mount(tester);
    channel.tick(connected);
    await deliver(tester);

    // Nothing claims an attribution before one has been measured.
    expect(find.text('Proxy'), findsNothing);

    channel.split(
      const TrafficSplit(proxyDown: 2048, directDown: 512, proxyUp: 1024, directUp: 256),
    );
    await deliver(tester);

    // One row per side, in each of the two cards.
    expect(find.text('Proxy'), findsNWidgets(2));
    expect(find.text('Direct'), findsNWidgets(2));
    expect(find.text('2.0 KB/s'), findsOneWidget); // proxy download
    expect(find.text('512 B/s'), findsOneWidget); // direct download
    expect(find.text('1.0 KB/s'), findsOneWidget); // proxy upload
    expect(find.text('256 B/s'), findsOneWidget); // direct upload
  });

  testWidgets('the split disappears when the tunnel stops', (tester) async {
    // Otherwise the last reading sits there looking like live traffic on a tunnel
    // that is no longer carrying any.
    await mount(tester);
    channel.tick(connected);
    channel.split(const TrafficSplit(proxyDown: 2048));
    await deliver(tester);
    expect(find.text('Proxy'), findsNWidgets(2));

    channel.tick(const TunnelStatus(stage: TunnelStage.stopped));
    await deliver(tester);
    expect(find.text('Proxy'), findsNothing);
  });

  test('the log buffer stays bounded', () async {
    for (var i = 0; i < 2000; i++) {
      channel.log('line $i');
    }
    await Future<void>.delayed(Duration.zero);
    expect(controller.logs, hasLength(500));
    expect(controller.logs.last.message, 'line 1999');
  });

  // The chart on the connect screen samples the same telemetry the counters do, so
  // its window is only ever as honest as what has actually arrived.
  testWidgets('the speed chart waits until it has a shape to draw', (tester) async {
    await mount(tester);
    channel.tick(connected);
    await deliver(tester);
    // One reading is a dot, not a line, and an empty card reads as broken rather
    // than idle.
    expect(find.text('Live speed'), findsNothing);

    channel.tick(
      const TunnelStatus(stage: TunnelStage.started, trafficAvailable: true, downlink: 4096),
    );
    await deliver(tester);
    expect(find.text('Live speed'), findsOneWidget);
    // Named, because an unlabelled rate above two live rates reads as a third one.
    expect(find.text('Peak 4.0 KB/s'), findsOneWidget);
  });

  testWidgets('the speed chart does not outlive the tunnel', (tester) async {
    await mount(tester);
    channel.tick(connected);
    await deliver(tester);
    channel.tick(
      const TunnelStatus(stage: TunnelStage.started, trafficAvailable: true, downlink: 4096),
    );
    await deliver(tester);
    expect(find.text('Live speed'), findsOneWidget);

    // A shape left over from the last session would sit there looking live.
    channel.tick(TunnelStatus.disconnected);
    await deliver(tester);
    expect(find.text('Live speed'), findsNothing);
  });

  // Counters mean nothing without a traffic source attached; the panel already shows
  // dashes rather than a convincing zero, and the chart must not contradict it.
  testWidgets('the speed chart ignores readings with no traffic source', (tester) async {
    await mount(tester);
    for (var i = 0; i < 5; i++) {
      channel.tick(TunnelStatus(stage: TunnelStage.started, downlink: i * 1000));
      await deliver(tester);
    }
    expect(find.text('Live speed'), findsNothing);
  });

  // A VPN client that says "connected" is answering the wrong question. The tunnel
  // coming up says the core started; it says nothing about whether a packet reaches
  // the other end, and the two look identical on screen.
  group('health', () {
    testWidgets('is unknown until something has been measured', (tester) async {
      await mount(tester);
      expect(controller.health, TunnelHealth.unknown);

      channel.tick(connected);
      await deliver(tester);
      expect(controller.health, TunnelHealth.unknown);

      // Measured, but the core reports a failed test as a delay of zero — which is
      // also what "never measured" looks like, hence the timestamp.
      channel.group(tag: 'S', delayMs: 0, testedAt: 0);
      await deliver(tester);
      expect(controller.health, TunnelHealth.unknown);
    });

    testWidgets('is healthy when the active server answers', (tester) async {
      await mount(tester);
      channel.tick(connected);
      await deliver(tester);
      channel.group(tag: 'S', delayMs: 120, testedAt: 1755000000);
      await deliver(tester);
      expect(controller.health, TunnelHealth.healthy);
      expect(find.text('Connected, but nothing is getting through'), findsNothing);
    });

    testWidgets('is stalled when it was measured and did not answer', (tester) async {
      await mount(tester);
      channel.tick(connected);
      await deliver(tester);
      channel.group(tag: 'S', delayMs: 0, testedAt: 1755000000);
      await deliver(tester);
      expect(controller.health, TunnelHealth.stalled);
      expect(find.text('Connected, but nothing is getting through'), findsOneWidget);
    });

    // Nothing goes through the proxy in Direct mode, so its reachability says nothing
    // about whether the phone has working internet. Warning there would be noise.
    testWidgets('says nothing in Direct mode', (tester) async {
      await mount(tester);
      channel.tick(
        const TunnelStatus(
          stage: TunnelStage.started,
          trafficAvailable: true,
          mode: ConfigBuilder.modeDirect,
        ),
      );
      await deliver(tester);
      channel.group(tag: 'S', delayMs: 0, testedAt: 1755000000);
      await deliver(tester);
      expect(controller.health, TunnelHealth.unknown);
      expect(find.text('Connected, but nothing is getting through'), findsNothing);
    });

    testWidgets('does not outlive the tunnel', (tester) async {
      await mount(tester);
      channel.tick(connected);
      await deliver(tester);
      channel.group(tag: 'S', delayMs: 0, testedAt: 1755000000);
      await deliver(tester);
      expect(controller.health, TunnelHealth.stalled);

      channel.tick(TunnelStatus.disconnected);
      await deliver(tester);
      expect(controller.health, TunnelHealth.unknown);
      expect(find.text('Connected, but nothing is getting through'), findsNothing);
    });

    // The symptom is on screen either way; this is the part that tells the reader
    // where to go next, and it is already in memory.
    testWidgets('carries the last thing the core complained about', (tester) async {
      await mount(tester);
      channel.tick(connected);
      await deliver(tester);
      channel._logs.add([
        const CoreLogEntry(level: 5, message: 'something ordinary'),
        const CoreLogEntry(level: 1, message: 'detour to an empty direct outbound'),
        const CoreLogEntry(level: 5, message: 'something later and ordinary'),
      ]);
      await deliver(tester);
      channel.group(tag: 'S', delayMs: 0, testedAt: 1755000000);
      await deliver(tester);

      expect(controller.lastCoreError, 'detour to an empty direct outbound');
      expect(find.text('detour to an empty direct outbound'), findsOneWidget);
    });

    // Health is published on the group signal, which exists so a latency reading does
    // not rebuild the tree. It has to be the exception, or the warning never appears.
    testWidgets('a change in it does notify, and a latency number does not', (tester) async {
      await mount(tester);
      channel.tick(connected);
      await deliver(tester);
      final settled = notifications();

      channel.group(tag: 'S', delayMs: 200, testedAt: 1755000000);
      await deliver(tester);
      expect(
        notifications(),
        greaterThan(settled),
        reason: 'going healthy is a change the whole screen has something to say about',
      );

      final afterHealthy = notifications();
      // A second reading that changes only the number must not. That separation is
      // the entire reason group updates travel on their own signal.
      channel.group(tag: 'S', delayMs: 210, testedAt: 1755000001);
      await deliver(tester);
      expect(notifications(), afterHealthy, reason: 'a latency number is not a state change');
    });
  });

  group('home at large text', () {
    final running = TunnelStatus(
      stage: TunnelStage.started,
      trafficAvailable: true,
      mode: 'rule',
      startedAt: DateTime.now().millisecondsSinceEpoch - 3725000,
    );

    Future<void> show(WidgetTester tester, {required double width, required double scale}) async {
      tester.view.physicalSize = Size(width, 2400);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester);
      channel.tick(running);
      await deliver(tester);
    }

    // The test font draws every glyph a full em wide, so "narrow" here is narrow for
    // that font, not for Roboto.
    testWidgets('roomy: one status line, and icons on the mode buttons', (tester) async {
      await show(tester, width: 1400, scale: 1.0);
      expect(find.text('  ·  '), findsOneWidget);
      expect(find.byIcon(Icons.alt_route), findsOneWidget);
    });

    testWidgets('cramped: status stacks without a stray dot, mode buttons drop icons', (
      tester,
    ) async {
      await show(tester, width: 360, scale: 2.0);
      expect(find.text('  ·  '), findsNothing);
      expect(find.textContaining(RegExp(r'^1:0\d:\d\d$')), findsOneWidget);
      expect(find.byIcon(Icons.alt_route), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // The core republishes its groups every second while connected, nearly always
  // unchanged. Each one used to redraw the whole server list, on whatever tab.
  testWidgets('a repeated group report does not signal the server list', (tester) async {
    await mount(tester);
    channel.tick(connected);
    await deliver(tester);
    var signals = 0;
    controller.groupsChanged.addListener(() => signals++);

    channel.group(tag: 'S', delayMs: 200, testedAt: 1755000000);
    await deliver(tester);
    expect(signals, 1);

    for (var i = 0; i < 5; i++) {
      channel.group(tag: 'S', delayMs: 200, testedAt: 1755000000);
      await deliver(tester);
    }
    expect(signals, 1, reason: 'the same report again is not news');

    channel.group(tag: 'S', delayMs: 200, testedAt: 1755000060);
    await deliver(tester);
    expect(signals, 2, reason: 'a fresh measurement is, even at the same number');
  });

  // Changing a setting raises a Reconnect prompt, and reconnecting is a stop followed
  // by a start. The platform's stop posts an intent and returns while the service
  // tears the tunnel down on another thread, so starting too early lets the teardown
  // finish last and take the new tunnel with it -- a reconnect that sometimes leaves
  // everything off, for no reason the user can see.
  group('reconnect', () {
    /// A connected tunnel with one server and nothing to download on the way up.
    Future<void> ready() async {
      await controller.updateSettings(ConfigBuilder(routing: const RoutingSettings()));
      await controller.addFromLink('trojan://pw@example.com:443#S');
      channel.tick(connected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      channel.calls.clear();
    }

    test('does not start again while the tunnel is still up', () async {
      await ready();
      final pending = controller.reconnect();

      // Long enough for the wrong version to have started by now.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(channel.calls, ['stop'], reason: 'the start must wait for the stop to land');

      channel.tick(TunnelStatus.disconnected);
      await pending;
      expect(channel.calls, ['stop', 'start']);
    });

    test('starts straight away when the tunnel is already down', () async {
      await ready();
      channel.tick(TunnelStatus.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      channel.calls.clear();

      await controller.reconnect().timeout(const Duration(seconds: 2));
      expect(channel.calls, ['stop', 'start']);
    });

    // Waiting forever would leave a tunnel that is neither up nor coming up, with
    // nothing on screen to say which. A start that fails is at least visible.
    test('gives up waiting rather than never starting', () async {
      await ready();
      // No stopped status is ever published.
      await controller.reconnect(stopTimeout: const Duration(milliseconds: 200));
      expect(channel.calls, ['stop', 'start']);
    });
  });

  // sing-box's selector restores its own last choice from the cache file and only
  // then falls back to the config's default, so a server picked here and applied by
  // reconnecting was silently overruled by whichever one was picked before it. The
  // app is the source of truth; the core's memory is a convenience.
  group('the core is told which server the app means', () {
    /// One selector holding two servers, reporting [now] as the live one.
    void publish({required String now}) => channel._groups.add([
      OutboundGroup(
        tag: 'proxy',
        type: 'selector',
        selected: now,
        selectable: true,
        items: const [
          OutboundItem(tag: 'Chosen', type: 'socks', delayMs: 90, testedAt: 1755000000),
          OutboundItem(tag: 'Remembered', type: 'wireguard', delayMs: 80, testedAt: 1755000000),
        ],
      ),
    ]);

    Future<void> ready() async {
      await controller.updateSettings(ConfigBuilder(routing: const RoutingSettings()));
      await controller.addFromLink('trojan://pw@example.com:443#Chosen');
      channel.tick(connected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      channel.selections.clear();
    }

    test('corrects the core when it restored something else', () async {
      await ready();
      publish(now: 'Remembered');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(channel.selections, [('proxy', 'Chosen')]);
    });

    test('says nothing when they already agree', () async {
      await ready();
      publish(now: 'Chosen');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(channel.selections, isEmpty);
    });

    // A server needing another core is only in the config when it is the selected
    // one, so its absence means the config predates the choice and a reconnect is
    // already coming. Ordering a selection the core cannot honour would only fail.
    test('waits rather than naming a server the config does not have', () async {
      await ready();
      channel._groups.add([
        const OutboundGroup(
          tag: 'proxy',
          type: 'selector',
          selected: 'Remembered',
          selectable: true,
          items: [OutboundItem(tag: 'Remembered', type: 'wireguard', delayMs: 80, testedAt: 1)],
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(channel.selections, isEmpty);
    });
  });

  // Anything the app measures for itself is only about the tunnel while the app's own
  // traffic goes through it. A speed test run from outside is a measurement of the
  // plain connection wearing the tunnel's name, so the screen has to be able to say so.
  group('whether this app is inside its own tunnel', () {
    const self = 'com.lupangoding.trefoil';

    Future<bool> withRules(PerAppMode mode, List<String> packages) async {
      await controller.updateSettings(
        ConfigBuilder(
          routing: const RoutingSettings(),
          perApp: PerAppRules(mode: mode, packages: packages),
        ),
      );
      return controller.appIsTunnelled;
    }

    test('it is, when no rule says otherwise', () async {
      expect(await withRules(PerAppMode.off, const []), isTrue);
      expect(await withRules(PerAppMode.include, const []), isTrue);
      expect(await withRules(PerAppMode.exclude, const []), isTrue);
    });

    test('an include list that leaves it out leaves it out', () async {
      expect(await withRules(PerAppMode.include, const ['com.other.app']), isFalse);
      expect(await withRules(PerAppMode.include, const ['com.other.app', self]), isTrue);
    });

    test('an exclude list that names it means what it says', () async {
      expect(await withRules(PerAppMode.exclude, const [self]), isFalse);
      expect(await withRules(PerAppMode.exclude, const ['com.other.app']), isTrue);
    });

    // The mode is what decides; a list left over from the other one must not.
    test('a list is read against the mode it belongs to', () async {
      expect(await withRules(PerAppMode.off, const [self]), isTrue);
    });
  });
  // Loopback is reachable by every app on the device, so the two other cores serve
  // SOCKS only to a client holding this session's credentials. The three halves of
  // that agreement are written in three places — the sing-box config, Xray's config
  // and the AmneziaWG start request — and any disagreement is a tunnel that comes up
  // and carries nothing.
  group('the loopback hand-off', () {
    const pq =
        'vless://11111111-2222-3333-4444-555555555555@1.2.3.4:31775'
        '?security=reality&fp=chrome&pbk=PUBKEY&sid=8e&sni=aws.amazon.com'
        '&pqv=VERIFYKEY&spx=%2Fabc&type=tcp&encryption=none#PQ';
    const awg = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=
Address = 10.8.1.2/32
Jc = 3
Jmin = 51
Jmax = 109
S1 = 123
S2 = 82
H1 = 410000001
H4 = 1700000001

[Peer]
PublicKey = bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.12:51820
''';

    ({int port, String user, String pass}) dialed(String config, String tag) {
      final outbound = ((jsonDecode(config) as Map)['outbounds'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((o) => o['tag'] == tag);
      expect(outbound['type'], 'socks');
      return (
        port: outbound['server_port']! as int,
        user: outbound['username']! as String,
        pass: outbound['password']! as String,
      );
    }

    test('every side agrees, and each connect draws a new set', () async {
      await controller.updateSettings(ConfigBuilder(routing: const RoutingSettings()));
      await controller.addFromLink(pq);
      await controller.addFromLink(awg);
      final awgTag = controller.servers.firstWhere((s) => s.requiresAmnezia).tag;

      await controller.connect();
      final first = channel.lastStart!;
      final socks = first.amneziaSocks!;
      expect(first.amneziaConfig, isNotNull);

      final toXray = dialed(first.config, 'PQ');
      final xrayInbound = ((jsonDecode(first.xrayConfig!) as Map)['inbounds'] as List).first as Map;
      final account = ((xrayInbound['settings'] as Map)['accounts'] as List).single as Map;
      expect(xrayInbound['port'], toXray.port);
      expect((account['user'], account['pass']), (toXray.user, toXray.pass));

      final toAmnezia = dialed(first.config, awgTag);
      expect(
        (toAmnezia.port, toAmnezia.user, toAmnezia.pass),
        (socks.amneziaPort, socks.username, socks.password),
      );
      expect(toAmnezia.port, isNot(toXray.port));

      await controller.connect();
      final second = channel.lastStart!.amneziaSocks!;
      expect(second.password, isNot(socks.password));
    });
  });

  // After an update the service restarts itself from the config the old version
  // left on disk, so what this version fixed there is not running yet — with
  // always-on VPN, possibly for weeks. The app has to say so.
  group('a tunnel still running an older config', () {
    const running = TunnelStatus(stage: TunnelStage.started, trafficAvailable: true);

    Future<TunnelController> launch({required int held}) async {
      final launchDir = Directory.systemTemp.createTempSync('trefoil-stale');
      addTearDown(() => launchDir.deleteSync(recursive: true));
      final launchChannel = _FakeChannel()
        ..launchStatus = running
        ..heldConfigVersion = held;
      addTearDown(launchChannel.close);
      final launched = TunnelController(
        channel: launchChannel,
        store: ProfileStore(directory: launchDir),
      );
      addTearDown(launched.dispose);
      await launched.init();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return launched;
    }

    test('asks for a reconnect', () async {
      expect((await launch(held: 0)).needsReconnect, isTrue);
    });

    test('says nothing when the running config is current', () async {
      final current = ConfigBuilder.generatedConfigVersion;
      expect((await launch(held: current)).needsReconnect, isFalse);
    });
  });
}
