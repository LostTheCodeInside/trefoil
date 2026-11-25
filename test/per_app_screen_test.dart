import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/tunnel_controller.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/main.dart';
import 'package:trefoil/ui/per_app_screen.dart';

class _Controller extends TunnelController {
  _Controller(this.apps);

  final PerAppMode apps;

  @override
  ConfigBuilder get settings => ConfigBuilder(
    perApp: PerAppRules(mode: apps, packages: const ['org.example.one']),
  );
}

/// The first word of [text] that is cut in two at the end of a line, if any.
String? _brokenWord(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: text, matching: find.byType(RichText)),
  );
  final label = paragraph.text.toPlainText();
  for (final word in RegExp(r'\S+').allMatches(label)) {
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: word.start, extentOffset: word.end),
    );
    if (boxes.map((box) => box.top.round()).toSet().length > 1) return word[0];
  }
  return null;
}

/// The bar holds a title of two lines, the modes and the search, and has to say how tall
/// it is up front. Saying too little squeezed the title out of sight.
void main() {
  const control = MethodChannel('trefoil/control');
  final messenger = TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  setUp(
    () => messenger.setMockMethodCallHandler(
      control,
      (call) async => call.method == 'installedApps' ? const <Object?>[] : null,
    ),
  );
  tearDown(() => messenger.setMockMethodCallHandler(control, null));

  Future<void> pump(WidgetTester tester, PerAppMode mode, Locale locale) async {
    final controller = _Controller(mode);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      TunnelScope(
        controller: controller,
        child: MaterialApp(
          key: UniqueKey(),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PerAppScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final (size, scale) in const [
    (Size(360, 800), 1.0),
    (Size(360, 800), 1.3),
    (Size(360, 800), 2.0),
    (Size(411, 914), 1.0),
    (Size(411, 914), 2.0),
    (Size(800, 360), 2.0),
  ]) {
    testWidgets('the bar has room for all of it at $size and x$scale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        for (final mode in PerAppMode.values) {
          await pump(tester, mode, locale);
          final reason = '$locale, ${mode.name}';
          expect(tester.takeException(), isNull, reason: reason);

          final toolbar = tester.getRect(find.byType(NavigationToolbar));
          expect(toolbar.height, greaterThanOrEqualTo(kToolbarHeight), reason: reason);
          for (final line in [l10n.perAppProxy, if (mode != PerAppMode.off) l10n.appsSelected(1)]) {
            final text = tester.getRect(find.text(line));
            expect(text.top, greaterThanOrEqualTo(toolbar.top), reason: '$reason: $line');
            expect(text.bottom, lessThanOrEqualTo(toolbar.bottom), reason: '$reason: $line');
          }

          final modes = find.byType(SegmentedButton<PerAppMode>);
          final search = tester.getRect(find.byType(SearchBar));
          expect(tester.getRect(modes).top, greaterThanOrEqualTo(toolbar.bottom), reason: reason);
          expect(search.top, greaterThanOrEqualTo(tester.getRect(modes).bottom), reason: reason);
          expect(tester.getRect(find.byType(AppBar)).bottom, search.bottom + 12, reason: reason);

          for (final label in [l10n.appsAll, l10n.appsOnlyThese, l10n.appsExceptThese]) {
            final text = find.descendant(of: modes, matching: find.text(label));
            final segment = find.ancestor(of: text, matching: find.byType(TextButton));
            final room = tester.getRect(segment).inflate(0.01);
            expect(room.expandToInclude(tester.getRect(text)), room, reason: '$reason: $label');
            expect(_brokenWord(tester, text), isNull, reason: '$reason: $label');
          }
        }
      }
    });
  }
}
