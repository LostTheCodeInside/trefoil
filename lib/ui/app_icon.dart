import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/app_icons.dart';

/// One app's launcher icon, with a placeholder for the moment before it arrives —
/// and for the apps Android has no icon to give.
///
/// The box is the same size either way, because a row that changes height when its
/// icon loads would shuffle the whole list while it scrolls.
class AppIcon extends StatelessWidget {
  const AppIcon(this.packageName, {super.key, this.size = 40});

  final String packageName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icons = AppIcons.instance;
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<Uint8List?>(
        future: icons.load(packageName),
        // Already-loaded bytes are handed over synchronously: without this a
        // FutureBuilder starts empty even for a future that is already complete, and
        // every rebuild would blink the placeholder for a frame.
        initialData: icons.cached(packageName),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) return _Placeholder(size: size);
          return Image.memory(
            bytes,
            width: size,
            height: size,
            filterQuality: FilterQuality.medium,
            // Bytes in hand is not yet a picture -- decoding takes a frame or two of
            // its own, and without this the row would go blank in between. The fade
            // is skipped when the decoder had the frame already, which is every
            // rebuild after the first: an icon that re-fades on every keystroke
            // would be worse than one that never faded at all.
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: frame == null ? _Placeholder(size: size) : child,
              );
            },
            // A corrupt or undecodable icon is a placeholder, not a red box in the
            // middle of the list.
            errorBuilder: (context, error, stack) => _Placeholder(size: size),
          );
        },
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size / 4),
      ),
      child: Icon(Icons.apps_outlined, size: size * 0.55, color: scheme.onSurfaceVariant),
    );
  }
}
