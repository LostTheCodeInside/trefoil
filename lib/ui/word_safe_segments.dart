import 'dart:math';

import 'package:flutter/material.dart';

/// A [SegmentedButton] that gives way rather than split a label in two.
///
/// Every segment gets the same share of the row, and Flutter cuts a one-word label
/// that is wider than its share wherever it runs out ("Langs / ung"): on a small
/// phone, at a large font size, or with one option more than usual. So the widest
/// label is measured first. Icons, the check mark included, only repeat what the
/// label and the colour say, so they give up their room first, all at once so the
/// segments stay alike. Then long labels go onto a second line if they may, and then
/// all of them are scaled down by the same amount.
///
/// Measures with LayoutBuilder, so it cannot be used where a parent asks for
/// intrinsic sizes, such as inside an AlertDialog.
class WordSafeSegments<T> extends StatelessWidget {
  const WordSafeSegments({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.icons = const {},
    this.canWrap = false,
    this.canStack = false,
  });

  /// The options in order. Without [icons], the selected one carries a check mark.
  final Map<T, String> labels;
  final Map<T, IconData> icons;
  final T selected;
  final ValueChanged<T> onSelected;

  /// Whether a label of several words may take two lines instead of shrinking.
  final bool canWrap;

  /// Whether this may turn into a list of radio buttons once the labels no longer fit
  /// at a readable size. Only where the page can grow taller.
  final bool canStack;

  /// M3's step down from its usual button label (14) to the smaller one (12). Relative
  /// to the font size chosen on the phone, so a larger one is not shrunk away.
  static const _smallest = 12 / 14;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final segment = constraints.maxWidth / labels.length;
        final widest = _widest(context);
        // M3 puts 12 + 16 of padding around an icon segment, an 18 px icon and an
        // 8 px gap inside it; 12 a side around a text-only one; and a hairline
        // between segments.
        if (widest <= segment - 55) return _row(withIcons: true);
        final room = segment - 26;
        if (widest <= room) return _row(withIcons: false);

        final shrink = room / (canWrap ? _widest(context, wrapped: true) : widest);
        if (canStack && shrink < _smallest) return _list();
        final row = _row(withIcons: false, wrap: canWrap);
        if (shrink >= 1) return row;
        final scaler = MediaQuery.textScalerOf(context);
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scaler.scale(14) / 14 * shrink)),
          child: row,
        );
      },
    );
  }

  /// The width every label fits into, or each of them on two lines when [wrapped].
  double _widest(BuildContext context, {bool wrapped = false}) => labels.values
      .map(
        (label) => [
          _width(context, label),
          if (wrapped)
            for (final space in ' '.allMatches(label))
              _width(context, label.replaceRange(space.start, space.end, '\n')),
        ].reduce(min),
      )
      .reduce(max);

  double _width(BuildContext context, String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: Theme.of(context).textTheme.labelLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  Widget _row({required bool withIcons, bool wrap = false}) => SegmentedButton<T>(
    segments: [
      for (final MapEntry(key: value, value: label) in labels.entries)
        ButtonSegment(
          value: value,
          label: wrap
              ? Text(label, maxLines: 2, textAlign: TextAlign.center)
              : FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, softWrap: false)),
          icon: withIcons && icons[value] != null ? Icon(icons[value], size: 18) : null,
        ),
    ],
    selected: {selected},
    showSelectedIcon: withIcons && icons.isEmpty,
    onSelectionChanged: (value) => onSelected(value.first),
  );

  Widget _list() => RadioGroup<T>(
    groupValue: selected,
    onChanged: (value) {
      if (value != null) onSelected(value);
    },
    child: Column(
      children: [
        for (final MapEntry(key: value, value: label) in labels.entries)
          RadioListTile<T>(value: value, title: Text(label), contentPadding: EdgeInsets.zero),
      ],
    ),
  );
}
