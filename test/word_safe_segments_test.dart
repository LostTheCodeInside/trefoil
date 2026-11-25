import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/warp.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/l10n_ext.dart';
import 'package:trefoil/ui/routing_screen.dart';
import 'package:trefoil/ui/word_safe_segments.dart';

class _Controller extends TunnelController {
  _Controller({required this.warp});

  final WarpAccount? warp;

  @override
  bool get isLoading => false;

  @override
  RoutingSettings get routing => RoutingSettings(warp: warp);
}

/// Every label on its [lines] and inside its own segment, at [size] or larger.
void expectWhole(
  WidgetTester tester,
  Iterable<String> labels, {
  required double size,
  int lines = 1,
}) {
  for (final label in labels) {
    final text = find.text(label);
    final segment = find.ancestor(of: text, matching: find.byType(TextButton));
    final box = tester.getRect(text);
    expect(
      tester.getRect(segment).inflate(0.01).expandToInclude(box),
      tester.getRect(segment).inflate(0.01),
      reason: '"$label" sticks out of its segment',
    );
    // The box is as tall as its lines of text, scaled the way they are drawn. Line
    // heights are whole pixels, so the size this gives is a little rough.
    final style = Theme.of(tester.element(text)).textTheme.labelLarge!;
    final drawn = box.height / lines / style.height!;
    expect(drawn, lessThan(size * 1.5), reason: '"$label" takes more lines than $lines');
    expect(drawn, greaterThan(size - 0.5), reason: '"$label" is too small to read');
  }
}

void main() {
  // The test font draws each glyph one em wide, so at 14 px, with M3's letter spacing,
  // the longest label is 4 x 14.1 = 56.4 px.
  const labels = {1: 'abcd', 2: 'efg', 3: 'hi'};

  var picked = 0;
  setUp(() => picked = 0);

  Future<void> pump(
    WidgetTester tester,
    double segment, {
    Map<int, String> labels = labels,
    bool canWrap = false,
    bool canStack = false,
    Map<int, IconData> icons = const {},
    double scale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Material(
          child: Center(
            child: SizedBox(
              width: segment * labels.length,
              child: WordSafeSegments<int>(
                labels: labels,
                icons: icons,
                selected: 1,
                onSelected: (value) => picked = value,
                canWrap: canWrap,
                canStack: canStack,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('the selected option has a check mark where there is room', (tester) async {
    await pump(tester, 112);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expectWhole(tester, labels.values, size: 14);

    await tester.tap(find.text('hi'));
    expect(picked, 3);
  });

  testWidgets('the check mark goes before any label is made smaller', (tester) async {
    await pump(tester, 84);
    expect(find.byIcon(Icons.check), findsNothing);
    expectWhole(tester, labels.values, size: 14);
  });

  testWidgets('icons go for every option at once', (tester) async {
    const icons = {1: Icons.alt_route, 2: Icons.public, 3: Icons.arrow_forward};
    await pump(tester, 112, icons: icons);
    for (final icon in icons.values) {
      expect(find.byIcon(icon), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsNothing);

    await pump(tester, 84, icons: icons);
    expect(find.byType(Icon), findsNothing);
    expectWhole(tester, labels.values, size: 14);
  });

  testWidgets('all labels shrink by the same amount', (tester) async {
    await pump(tester, 76, canStack: true);
    expectWhole(tester, labels.values, size: 12);
    final heights = {for (final label in labels.values) tester.getSize(find.text(label)).height};
    expect(heights, hasLength(1));
    expect(heights.single, lessThan(20));
  });

  testWidgets('labels too small to read in a row become a list', (tester) async {
    await pump(tester, 60, canStack: true);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.byType(RadioListTile<int>), findsNWidgets(3));

    await tester.tap(find.text('efg'));
    expect(picked, 2);
  });

  testWidgets('a font size chosen on the phone is not shrunk away', (tester) async {
    // At the usual size this is the roomy case above.
    await pump(tester, 112, canStack: true, scale: 2);
    expect(find.byType(RadioListTile<int>), findsNWidgets(3));
  });

  testWidgets('a row that cannot become a list keeps its labels whole', (tester) async {
    await pump(tester, 60);
    expectWhole(tester, labels.values, size: 8);
  });

  testWidgets('a long label takes a second line before any label shrinks', (tester) async {
    const labels = {1: 'abcd efg', 2: 'hij', 3: 'kl'};
    await pump(tester, 84, labels: labels, canWrap: true);
    expect(find.byIcon(Icons.check), findsNothing);
    expectWhole(tester, ['abcd efg'], size: 14, lines: 2);
    expectWhole(tester, ['hij', 'kl'], size: 14);

    // Where it is not allowed to, it shrinks.
    await pump(tester, 84, labels: labels);
    expectWhole(tester, labels.values, size: 7);
  });

  testWidgets('a label on two lines shrinks rather than break a word', (tester) async {
    await pump(tester, 60, labels: {1: 'ab cd efgh', 2: 'ijkl', 3: 'm'}, canWrap: true);
    expectWhole(tester, ['ab cd efgh'], size: 6, lines: 2);
    expectWhole(tester, ['ijkl', 'm'], size: 6);
  });

  testWidgets('every action of a rule stays whole, in every language', (tester) async {
    final account = WarpAccount(
      privateKey: 'a',
      peerPublicKey: 'b',
      endpointHost: '203.0.113.1',
      endpointPort: 2408,
      addressV4: '172.16.0.2',
      addressV6: 'fd00::2',
      reserved: const [1, 2, 3],
      registeredAt: DateTime.utc(2026),
    );
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final warp in [null, account]) {
      final controller = _Controller(warp: warp);
      for (final locale in AppLocalizations.supportedLocales) {
        for (final (width, scale) in [(360.0, 1.0), (360.0, 1.3), (411.0, 1.0), (411.0, 2.0)]) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1600);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pumpWidget(
            TunnelScope(
              controller: controller,
              child: MaterialApp(
                key: UniqueKey(),
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const RoutingScreen(),
              ),
            ),
          );
          await tester.pump();
          await tester.tap(find.byType(FloatingActionButton));
          await tester.pumpAndSettle();

          final l10n = lookupAppLocalizations(locale);
          final actions = [
            for (final action in RuleAction.values)
              if (action != RuleAction.warp || warp != null) action.label(l10n),
          ];
          if (find.byType(SegmentedButton<RuleAction>).evaluate().isNotEmpty) {
            expectWhole(tester, actions, size: 12 * scale);
          } else {
            expect(find.byType(RadioListTile<RuleAction>), findsNWidgets(actions.length));
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
  });
}
