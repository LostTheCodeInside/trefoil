import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Material 3 fade-through between top-level destinations.
///
/// Not an [AnimatedSwitcher] and not a plain [IndexedStack]. A switcher would build
/// the incoming screen from scratch and throw the outgoing one away, taking its
/// scroll position, its half-typed text and its stream subscriptions with it. A plain
/// IndexedStack keeps all of that but swaps in a single frame, which reads as a jump.
///
/// So every child stays in the tree for its whole life, and only the two taking part
/// in a switch are painted: the outgoing one fades out over the first stretch, the
/// incoming one fades and scales up over the rest. That is the fade-through spec —
/// destinations that are siblings rather than parent and child get no directional
/// movement, because there is no direction to imply.
class FadeThroughStack extends StatefulWidget {
  const FadeThroughStack({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<FadeThroughStack> createState() => _FadeThroughStackState();
}

class _FadeThroughStackState extends State<FadeThroughStack> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    // Starts settled: the first frame is a destination already in place, not one
    // animating in from nothing.
    value: 1,
  );

  late final Animation<double> _outgoing = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.3),
  );
  late final Animation<double> _incoming = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.3, 1, curve: Curves.easeOut),
  );

  late int _previous = widget.index;

  /// Destinations built so far. Launch lays out only the one it lands on; the rest
  /// follow one at a time once the app has been idle for a moment, so the first
  /// switch to them is not also the frame that builds them.
  late final Set<int> _opened = {widget.index};
  Timer? _warm;

  @override
  void initState() {
    super.initState();
    _warmNext(const Duration(seconds: 1));
  }

  void _warmNext(Duration after) {
    _warm = Timer(after, () {
      if (!mounted) return;
      // Not in the middle of a switch: that frame budget belongs to the animation.
      if (_controller.isAnimating) return _warmNext(const Duration(milliseconds: 500));
      final next = [for (var i = 0; i < widget.children.length; i++) i]
          .where((i) => !_opened.contains(i))
          .firstOrNull;
      if (next == null) return;
      setState(() => _opened.add(next));
      _warmNext(const Duration(milliseconds: 400));
    });
  }

  @override
  void didUpdateWidget(FadeThroughStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _previous = oldWidget.index;
      _opened.add(widget.index);
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _warm?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Stack(
        fit: StackFit.expand,
        children: [for (var i = 0; i < widget.children.length; i++) _layer(i)],
      ),
    );
  }

  Widget _layer(int index) {
    final incoming = index == widget.index;
    final outgoing = !_controller.isCompleted && index == _previous && !incoming;
    final visible = incoming || outgoing;

    // Every child gets the same wrapper shape in every state, and only the values
    // inside it change. Swapping one wrapper for another would change the element
    // type at that slot, which unmounts the screen below it and takes its scroll
    // position, its text fields and its subscriptions with it — the exact failure
    // this widget exists to avoid. Settled, all four wrappers are no-ops: an opacity
    // of 1 and an identity transform both take their renderer's cheap path.
    return TickerMode(
      // A screen nobody is looking at should not be driving animations and asking
      // the engine for frames. The one leaving keeps ticking until it is gone.
      enabled: visible,
      child: Offstage(
        offstage: !visible,
        child: IgnorePointer(
          // Both screens are painted during the cross-fade, so without this the one
          // departing would still be taking taps meant for the one arriving.
          ignoring: !incoming,
          child: Opacity(
            opacity: incoming
                ? _incoming.value
                : outgoing
                ? 1 - _outgoing.value
                : 0,
            child: Transform.scale(
              scale: incoming ? 0.92 + 0.08 * _incoming.value : 1,
              child: _opened.contains(index) ? widget.children[index] : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

/// A [ListenableBuilder] that holds still while it is out of sight.
///
/// The destinations behind [FadeThroughStack] stay mounted, and Offstage hides them
/// without stopping them building: a list that redraws for every latency report did
/// so on whichever tab was showing. This keeps listening, but a change that arrives
/// while [TickerMode] is off only marks it stale, and it builds once on its way back.
class VisibleListenableBuilder extends StatefulWidget {
  const VisibleListenableBuilder({super.key, required this.listenable, required this.builder});

  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<VisibleListenableBuilder> createState() => _VisibleListenableBuilderState();
}

class _VisibleListenableBuilderState extends State<VisibleListenableBuilder> {
  ValueListenable<TickerModeData>? _visible;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.getValuesNotifier(context);
    if (visible != _visible) {
      _visible?.removeListener(_shown);
      _visible = visible..addListener(_shown);
    }
  }

  @override
  void didUpdateWidget(VisibleListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    _visible?.removeListener(_shown);
    super.dispose();
  }

  void _changed() {
    if (_visible?.value.enabled ?? true) {
      setState(() {});
    } else {
      _stale = true;
    }
  }

  void _shown() {
    if (_stale && (_visible?.value.enabled ?? false)) {
      _stale = false;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
