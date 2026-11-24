import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../core/tunnel_controller.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'about_screen.dart';
import 'error_text.dart';
import 'home_screen.dart';
import 'motion.dart';
import 'servers_screen.dart';
import 'settings_screen.dart';

/// Top-level navigation: connect, choose a server, everything else.
///
/// The log view used to be the third destination. It is a debugging tool rather than
/// a place to go, and giving it a third of the navigation bar said otherwise — so it
/// moved under Settings, which took the slot instead.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  /// Whether the change waiting for a reconnect has already been mentioned.
  bool _reconnectOffered = false;

  /// That mention, while it is up.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _reconnectOffer;

  /// Whether a newer build is waiting, which badges the Settings destination: the
  /// snackbar is gone in seconds, and About is two taps deep.
  bool _updateReady = false;

  /// Built once and handed over as the same instances on every rebuild. This shell
  /// rebuilds on every controller change; fresh tab widgets each time would rebuild
  /// all three tabs with it and undo what [_HeldWhileHidden] holds back.
  late final List<Widget> _tabs = [
    // The connect screen has nowhere to send someone with no servers, so the shell
    // -- which owns the tab index -- hands it a way to get there.
    _HeldWhileHidden(child: HomeScreen(onAddServer: () => setState(() => _index = 1))),
    const _HeldWhileHidden(child: ServersScreen()),
    const _HeldWhileHidden(child: SettingsScreen()),
  ];

  @override
  void initState() {
    super.initState();
    // Read as well as listened to: an update found before this shell was built (a
    // locale change rebuilds it) would otherwise go unbadged until the next change.
    _updateReady = AppUpdater.instance.stage == UpdateStage.available;
    AppUpdater.instance.addListener(_onUpdater);
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerUpdate());
  }

  @override
  void dispose() {
    AppUpdater.instance.removeListener(_onUpdater);
    super.dispose();
  }

  void _onUpdater() {
    final ready = AppUpdater.instance.stage == UpdateStage.available;
    if (ready != _updateReady && mounted) setState(() => _updateReady = ready);
  }

  /// Asks the release server once per launch, and says something only when there is
  /// a newer build: a failed check is not worth interrupting anyone over, and the
  /// About screen can always be asked directly.
  Future<void> _offerUpdate() async {
    final update = await AppUpdater.instance.checkQuietly();
    if (update == null || !mounted) return;
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.appUpdateSnack(update.versionName)),
        behavior: SnackBarBehavior.floating,
        // Having an action no longer makes it leave on its own, and one that stays
        // holds back everything said after it.
        persist: false,
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: l10n.appUpdateView,
          onPressed: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
        ),
      ),
    );
  }

  /// Mentions the reconnect on the page the change was made on, when that page covers
  /// this shell and the strip with it. In passing only: the strip is what stays.
  void _offerReconnect(bool needed) {
    if (!needed) {
      _reconnectOffer?.close();
      _reconnectOffer = null;
      return;
    }
    if (!Navigator.of(context).canPop()) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final offer = messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.settingsChangedReconnect),
        behavior: SnackBarBehavior.floating,
        persist: false,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: l10n.actionReconnect,
          onPressed: () => TunnelScope.read(context).reconnect(),
        ),
      ),
    );
    _reconnectOffer = offer;
    offer.closed.then((_) {
      if (identical(_reconnectOffer, offer)) _reconnectOffer = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);

    // The notification is written by the service, which has no way to look up a
    // translation -- so the current ones are handed down from here, where the
    // language is known, and travel with the next start request.
    controller.setNotificationLabels(proxy: l10n.actionProxy, direct: l10n.actionDirect);

    // Action failures are reported once, as a snackbar, then cleared. Leaving them
    // on screen would mean a transient network error looks like a permanent state.
    final error = controller.lastActionError;
    if (error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          // Waiting its turn behind another message would put it long after whatever
          // it is about.
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(describeError(l10n, error)),
              behavior: SnackBarBehavior.floating,
              showCloseIcon: true,
            ),
          );
        controller.clearActionError();
      });
    }

    // Most settings live in the generated config, so they only take effect on the
    // next connect. Mode and server switches are applied live and deliberately do
    // not raise this.
    final needsReconnect = controller.needsReconnect;
    if (needsReconnect != _reconnectOffered) {
      _reconnectOffered = needsReconnect;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _offerReconnect(needsReconnect);
      });
    }

    if (controller.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final body = FadeThroughStack(index: _index, children: _tabs);

    // A rail on anything wide enough for one. A bottom bar on a tablet or an
    // unfolded foldable wastes the short dimension -- the one a list needs -- and
    // puts the destinations at the far edge of a two-handed grip.
    if (MediaQuery.sizeOf(context).width >= railBreakpoint) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              labelType: NavigationRailLabelType.all,
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.shield_outlined),
                  selectedIcon: const Icon(Icons.shield),
                  label: Text(l10n.navConnect),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.dns_outlined),
                  selectedIcon: const Icon(Icons.dns),
                  label: Text(l10n.navServers),
                ),
                NavigationRailDestination(
                  icon: Badge(isLabelVisible: _updateReady, child: const Icon(Icons.tune_outlined)),
                  selectedIcon: Badge(isLabelVisible: _updateReady, child: const Icon(Icons.tune)),
                  label: Text(l10n.settingsTitle),
                ),
              ],
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: body),
                  _ReconnectStrip(visible: needsReconnect),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ReconnectStrip(visible: needsReconnect),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.shield_outlined),
                selectedIcon: Icon(Icons.shield),
                label: l10n.navConnect,
              ),
              NavigationDestination(
                icon: Icon(Icons.dns_outlined),
                selectedIcon: Icon(Icons.dns),
                label: l10n.navServers,
              ),
              NavigationDestination(
                icon: Badge(isLabelVisible: _updateReady, child: const Icon(Icons.tune_outlined)),
                selectedIcon: Badge(isLabelVisible: _updateReady, child: const Icon(Icons.tune)),
                label: l10n.settingsTitle,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Says that what was changed is not yet what is running, for as long as that is so.
///
/// Part of the layout rather than a message over it. As a message it had to stay up
/// until acted on, and everything said in the meantime, errors included, waited in
/// line behind it.
class _ReconnectStrip extends StatelessWidget {
  const _ReconnectStrip({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Semantics(
              container: true,
              liveRegion: true,
              child: Material(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      Icon(Icons.sync, size: 20, color: scheme.onSecondaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.settingsChangedReconnect,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => TunnelScope.read(context).reconnect(),
                        child: Text(l10n.actionReconnect),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// Holds a tab still while nobody can see it.
///
/// A tab is out of sight when another one is selected, or when a page has been
/// pushed over the whole shell, as every Settings screen is. Either way it stays
/// mounted, and without this it rebuilt for every controller change: a toggle on a
/// Settings page redrew all three tabs underneath it. Here a change that arrives out
/// of sight is held, and the tab rebuilds once when it comes back into view.
///
/// Its own [TickerMode] is turned off while covered too, which the stack's already is
/// for tabs not selected, so the per-second redraws further down (the clock, the
/// chart, the server list) stop along with it.
class _HeldWhileHidden extends StatefulWidget {
  const _HeldWhileHidden({required this.child});

  final Widget child;

  @override
  State<_HeldWhileHidden> createState() => _HeldWhileHiddenState();
}

class _HeldWhileHiddenState extends State<_HeldWhileHidden> {
  final _relay = _Relay();
  TunnelController? _controller;
  ValueListenable<TickerModeData>? _selected;
  Animation<double>? _coveredBy;
  bool _covered = false;
  bool _held = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = TunnelScope.read(context);
    if (controller != _controller) {
      _controller?.removeListener(_changed);
      _controller = controller..addListener(_changed);
    }
    final selected = TickerMode.getValuesNotifier(context);
    if (selected != _selected) {
      _selected?.removeListener(_maybeRelease);
      _selected = selected..addListener(_maybeRelease);
    }
    // A pushed page drives this route's secondary animation to the end; a sheet or a
    // dialog does not, and the shell is still in view behind one of those.
    final coveredBy = ModalRoute.of(context)?.secondaryAnimation;
    if (coveredBy != _coveredBy) {
      _coveredBy?.removeStatusListener(_coverChanged);
      _coveredBy = coveredBy?..addStatusListener(_coverChanged);
      _covered = coveredBy?.isCompleted ?? false;
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _selected?.removeListener(_maybeRelease);
    _coveredBy?.removeStatusListener(_coverChanged);
    _relay.dispose();
    super.dispose();
  }

  bool get _inView => !_covered && (_selected?.value.enabled ?? true);

  void _changed() {
    if (_inView) {
      _relay.ping();
    } else {
      _held = true;
    }
  }

  void _maybeRelease() {
    if (_held && _inView) {
      _held = false;
      _relay.ping();
    }
  }

  void _coverChanged(AnimationStatus status) {
    final covered = status.isCompleted;
    if (covered == _covered) return;
    setState(() => _covered = covered);
    _maybeRelease();
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: !_covered,
    child: TunnelScope(controller: _controller!, changes: _relay, child: widget.child),
  );
}

class _Relay extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Width at which the bottom bar becomes a rail.
///
/// Material's own medium breakpoint. A phone in landscape clears it too, which is
/// the point: that is exactly where a bottom bar costs the most height.
const double railBreakpoint = 600;

/// Caps how wide content is allowed to get.
///
/// A list row stretched across a tablet puts its title and its trailing value at
/// opposite edges of the screen, with nothing in between -- the eye has to travel
/// the whole width to pair them. Below the cap this changes nothing.
class AdaptiveBody extends StatelessWidget {
  const AdaptiveBody({super.key, required this.child, this.maxWidth = 720});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// Bottom padding that clears the system navigation bar.
///
/// From Android 15, an app targeting SDK 35+ is laid out edge to edge whether it asks
/// to be or not, so a scrollable's last item ends up behind the navigation bar. The
/// tabbed screens are unaffected because the NavigationBar already occupies that
/// space; every pushed route has to add the inset itself.
///
/// [extra] is the padding the screen wanted anyway — for a FAB to clear, say.
double bottomInset(BuildContext context, {double extra = 0}) =>
    MediaQuery.paddingOf(context).bottom + extra;

/// Bottom padding for a modal sheet: clears the keyboard when it is up, and the
/// navigation bar when it is not.
///
/// Adding both is correct rather than double-counting, because `padding` is what is
/// left after `viewInsets` are taken out — a raised keyboard already covers the
/// navigation bar, and `padding.bottom` goes to zero accordingly.
double sheetInset(BuildContext context, {double extra = 0}) =>
    MediaQuery.viewInsetsOf(context).bottom + MediaQuery.paddingOf(context).bottom + extra;

/// Formats a byte count the way the core does, so the UI and the logs agree.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}
