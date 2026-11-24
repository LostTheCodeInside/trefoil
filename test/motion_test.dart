import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/tunnel_status.dart';
import 'package:trefoil/ui/home_screen.dart';
import 'package:trefoil/ui/motion.dart';

void main() {
  group('FadeThroughStack', () {
    Future<void> mount(WidgetTester tester, ValueNotifier<int> index) {
      return tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: index,
            builder: (context, value, _) => FadeThroughStack(
              index: value,
              children: const [
                _Tab(name: 'a'),
                _Tab(name: 'b'),
                _Tab(name: 'c'),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('shows only the selected destination', (tester) async {
      final index = ValueNotifier(0);
      addTearDown(index.dispose);
      await mount(tester, index);

      expect(find.text('a 0'), findsOneWidget);
      expect(find.text('b 0'), findsNothing);
      expect(find.text('c 0'), findsNothing);
    });

    // The reason this is not an AnimatedSwitcher. A tab that forgets its scroll
    // position, its half-typed text or its subscriptions every time you glance at
    // another one is worse than no animation at all.
    testWidgets('a destination keeps its state while hidden', (tester) async {
      final index = ValueNotifier(0);
      addTearDown(index.dispose);
      await mount(tester, index);

      await tester.tap(find.text('a 0'));
      await tester.pump();
      expect(find.text('a 1'), findsOneWidget);

      index.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('b 0'), findsOneWidget);

      index.value = 0;
      await tester.pumpAndSettle();
      expect(find.text('a 1'), findsOneWidget, reason: 'the tap must have survived');
    });

    testWidgets('the outgoing destination is gone once the switch finishes', (tester) async {
      final index = ValueNotifier(0);
      addTearDown(index.dispose);
      await mount(tester, index);

      index.value = 2;
      await tester.pump();
      // Mid-transition both are on screen, which is what a fade-through is.
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('a 0'), findsOneWidget);
      expect(find.text('c 0'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('a 0'), findsNothing);
      expect(find.text('c 0'), findsOneWidget);
    });

    // Both are painted during the cross-fade, so without the guard the departing
    // screen would still be taking taps meant for the one arriving.
    testWidgets('the departing destination does not take taps', (tester) async {
      final index = ValueNotifier(0);
      addTearDown(index.dispose);
      await mount(tester, index);

      index.value = 1;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      await tester.tapAt(tester.getCenter(find.byType(FadeThroughStack)));
      await tester.pumpAndSettle();

      expect(find.text('b 1'), findsOneWidget);
      index.value = 0;
      await tester.pumpAndSettle();
      expect(find.text('a 0'), findsOneWidget, reason: 'the tap must not have landed here');
    });

    // A hidden screen that goes on driving its animations asks the engine for frames
    // nobody is looking at -- the connect button's halo repeats forever.
    testWidgets('a hidden destination has its ticker muted', (tester) async {
      final index = ValueNotifier(0);
      addTearDown(index.dispose);
      await mount(tester, index);
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('a ticking', skipOffstage: false), findsOneWidget);
      expect(find.text('b still', skipOffstage: false), findsOneWidget);

      index.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('a still', skipOffstage: false), findsOneWidget);
      expect(find.text('b ticking', skipOffstage: false), findsOneWidget);
    });
  });

  group('FadeThroughStack building', () {
    // Launch pays for the screen it lands on and nothing else.
    testWidgets('only the first destination is built at launch', (tester) async {
      final index = ValueNotifier(0);
      addTearDown(index.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: index,
            builder: (context, value, _) => FadeThroughStack(
              index: value,
              children: const [
                _Tab(name: 'a'),
                _Tab(name: 'b'),
                _Tab(name: 'c'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('b 0', skipOffstage: false), findsNothing);
      expect(find.text('c 0', skipOffstage: false), findsNothing);

      // Opening one before the idle build has got to it builds it on the spot.
      index.value = 2;
      await tester.pumpAndSettle();
      expect(find.text('c 0'), findsOneWidget);
    });

    // ...and the rest are built while nothing is happening, one per frame, so the
    // first switch to them is not also the frame that builds them.
    testWidgets('the rest are built once the app is idle', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FadeThroughStack(
            index: 0,
            children: [
              _Tab(name: 'a'),
              _Tab(name: 'b'),
              _Tab(name: 'c'),
            ],
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.text('b 0', skipOffstage: false), findsOneWidget);
      expect(find.text('c 0', skipOffstage: false), findsNothing);

      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('c 0', skipOffstage: false), findsOneWidget);
    });
  });

  group('VisibleListenableBuilder', () {
    testWidgets('holds changes while hidden and builds once on return', (tester) async {
      final signal = ValueNotifier(0);
      final shown = ValueNotifier(true);
      addTearDown(signal.dispose);
      addTearDown(shown.dispose);
      var builds = 0;

      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (context, enabled, child) => TickerMode(enabled: enabled, child: child!),
          child: VisibleListenableBuilder(
            listenable: signal,
            builder: (context) {
              builds++;
              return Text('${signal.value}', textDirection: TextDirection.ltr);
            },
          ),
        ),
      );
      expect(builds, 1);

      signal.value = 1;
      await tester.pump();
      expect(builds, 2, reason: 'in view, a change is drawn');

      shown.value = false;
      await tester.pump();
      for (var i = 2; i < 12; i++) {
        signal.value = i;
        await tester.pump();
      }
      expect(builds, 2, reason: 'out of sight, ten changes are only held');

      shown.value = true;
      await tester.pump();
      expect(builds, 3, reason: 'back in view, it catches up in one build');
      expect(find.text('11'), findsOneWidget);

      shown.value = false;
      await tester.pump();
      shown.value = true;
      await tester.pump();
      expect(builds, 3, reason: 'nothing held, nothing to rebuild for');
    });
  });

  group('uptime', () {
    test('reads mm:ss below an hour and h:mm:ss above it', () {
      expect(formatUptime(Duration.zero), '00:00');
      expect(formatUptime(const Duration(seconds: 9)), '00:09');
      expect(formatUptime(const Duration(minutes: 14, seconds: 32)), '14:32');
      expect(formatUptime(const Duration(minutes: 59, seconds: 59)), '59:59');
      expect(formatUptime(const Duration(hours: 1)), '1:00:00');
      expect(formatUptime(const Duration(hours: 26, minutes: 3, seconds: 7)), '26:03:07');
    });

    // The start time is the device's wall clock, so moving the clock forward while
    // connected can hand this a negative duration.
    test('a clock moved forward does not produce a negative uptime', () {
      expect(formatUptime(const Duration(seconds: -5)), '00:00');
      expect(formatUptime(const Duration(hours: -3)), '00:00');
    });
  });

  group('start time', () {
    test('comes across the channel and reads back as a time', () {
      final status = TunnelStatus.fromMap(const {'stage': 'started', 'startedAt': 1755000000000});
      expect(status.startedAt, 1755000000000);
      expect(status.startedAtTime, DateTime.fromMillisecondsSinceEpoch(1755000000000));
    });

    // Absent for a tunnel that is not up, and absent from a payload written before
    // the field existed. Neither may be reported as 1970.
    test('is absent rather than zero when the tunnel is not up', () {
      expect(TunnelStatus.fromMap(const {'stage': 'stopped'}).startedAtTime, isNull);
      expect(TunnelStatus.fromMap(const {'stage': 'started'}).startedAtTime, isNull);
      expect(TunnelStatus.disconnected.startedAtTime, isNull);
    });
  });
}

class _Tab extends StatefulWidget {
  const _Tab({required this.name});

  final String name;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => Material(
    child: GestureDetector(
      onTap: () => setState(() => taps++),
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.name} $taps'),
              Builder(
                builder: (context) => Text(
                  '${widget.name} ${TickerMode.valuesOf(context).enabled ? 'ticking' : 'still'}',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
