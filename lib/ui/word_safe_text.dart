import 'package:flutter/material.dart';

/// A [Text] that shrinks rather than split a word in two.
///
/// Text wraps between words, but a single word wider than its box has nowhere to
/// break and Flutter cuts it wherever it runs out ("Маршрутизаци / я"). That happens
/// at the largest font sizes, in the languages with the longest words, in rows that
/// share their width with an icon and a switch. Here the longest word is measured
/// first, and if it does not fit, the whole text is drawn just small enough that it
/// does. Anything that already fits is an ordinary Text.
///
/// Measures with LayoutBuilder, so it cannot be used where a parent asks for
/// intrinsic sizes, such as inside an AlertDialog.
class WordSafeText extends StatelessWidget {
  const WordSafeText(this.data, {super.key, this.style, this.maxLines, this.overflow});

  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  static final _space = RegExp(r'\s+');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final widest = constraints.hasBoundedWidth ? _widestWord(context, scaler) : 0.0;
        final fits = widest <= constraints.maxWidth;
        return Text(
          data,
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          textScaler: fits
              ? null
              // A little under the exact ratio: a word measured to fit to the pixel
              // can still be pushed onto a second line by rounding.
              : TextScaler.linear(scaler.scale(14) / 14 * constraints.maxWidth / widest * 0.97),
        );
      },
    );
  }

  double _widestWord(BuildContext context, TextScaler scaler) {
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    var widest = 0.0;
    for (final word in data.split(_space)) {
      if (word.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(text: word, style: resolved),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    return widest;
  }
}
