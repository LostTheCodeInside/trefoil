import 'dart:typed_data';

import 'tunnel_channel.dart';

/// Launcher icons for the per-app list, fetched once each and kept.
///
/// The list this feeds rebuilds on every keystroke in its search box and on every
/// checkbox, so a fetch started from `build` would be a platform call per row per
/// keystroke. Two things prevent that: [load] hands back the same future for a
/// package it has already been asked about, and [cached] answers synchronously once
/// the bytes are in — which is also what stops a rebuild flashing the placeholder
/// back in for a frame.
///
/// Kept, but not forever: a few hundred icons at 40dp is memory that would never be
/// given back on a phone with a full app drawer, so the map is capped and drops what
/// was asked for longest ago.
class AppIcons {
  AppIcons({Future<Uint8List?> Function(String)? fetch, this.capacity = 192})
    : _fetch = fetch ?? TunnelChannel.instance.appIcon;

  /// The app's own. A second instance would mean a second copy of every icon.
  static final AppIcons instance = AppIcons();

  final Future<Uint8List?> Function(String) _fetch;

  /// How many to keep — far more than fit on a screen, so scrolling back up never
  /// reloads, and small enough that the total stays bounded.
  final int capacity;

  /// A Dart map keeps insertion order, which is what makes the eviction below
  /// first-in-first-out.
  final _icons = <String, _Icon>{};

  /// The bytes for [packageName] if they have already arrived, else null. Null here
  /// means "not yet" or "there is no icon"; the caller draws the same placeholder
  /// for both, so it has no reason to tell them apart.
  Uint8List? cached(String packageName) => _icons[packageName]?.bytes;

  Future<Uint8List?> load(String packageName) {
    final known = _icons[packageName];
    if (known != null) return known.future;

    final icon = _Icon();
    // In the map before the first await, so two rows asking at once share one call.
    _icons[packageName] = icon;
    while (_icons.length > capacity) {
      _icons.remove(_icons.keys.first);
    }
    icon.future = _load(packageName, icon);
    return icon.future;
  }

  Future<Uint8List?> _load(String packageName, _Icon icon) async {
    try {
      return icon.bytes = await _fetch(packageName);
    } catch (_) {
      // An app with no icon comes back as null and is remembered as such. A thrown
      // error is different — the channel was not there to answer — and forgetting it
      // is what lets the next build try again rather than showing a placeholder for
      // the rest of the session.
      if (identical(_icons[packageName], icon)) _icons.remove(packageName);
      return null;
    }
  }
}

class _Icon {
  late final Future<Uint8List?> future;
  Uint8List? bytes;
}
