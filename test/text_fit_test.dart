import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/ui/word_safe_text.dart';

Future<Text> _render(WidgetTester tester, String text, double width) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: width,
          child: WordSafeText(text, style: const TextStyle(fontSize: 20)),
        ),
      ),
    ),
  );
  return tester.widget<Text>(find.byType(Text));
}

void main() {
  // The test font draws each glyph one em wide, so a 20 px word of n letters is 20n
  // pixels: easy to reason about here.
  testWidgets('text whose words fit is left alone', (tester) async {
    final text = await _render(tester, 'one two three', 120);
    expect(text.textScaler, isNull);
  });

  testWidgets('a word wider than its box shrinks the text instead of splitting', (tester) async {
    // Ten letters, 200 px, in a 100 px box.
    final text = await _render(tester, 'abcdefghij and more', 100);
    expect(text.textScaler, isNotNull);
    expect(text.textScaler!.scale(20), lessThanOrEqualTo(10.0));

    final paragraph = tester.renderObject<RenderParagraph>(find.byType(RichText));
    // Still one line for the long word: the caret after its last letter sits on the
    // same line as the caret before its first.
    final first = paragraph.getOffsetForCaret(const TextPosition(offset: 0), Rect.zero);
    final last = paragraph.getOffsetForCaret(
      const TextPosition(offset: 10, affinity: TextAffinity.upstream),
      Rect.zero,
    );
    expect(last.dy, first.dy);
  });

  testWidgets('without a bounded width there is nothing to fit', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: UnconstrainedBox(child: WordSafeText('abcdefghij')),
      ),
    );
    expect(tester.widget<Text>(find.byType(Text)).textScaler, isNull);
  });
}
