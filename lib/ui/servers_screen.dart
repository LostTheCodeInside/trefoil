import 'dart:async';

import 'package:flutter/material.dart';

import '../core/profile/amnezia_obfuscation.dart';
import '../core/profile/outbound.dart';
import '../core/profile/server_usage.dart';
import '../core/tunnel_controller.dart';
import '../core/tunnel_status.dart';
import '../core/profile/profile_store.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'motion.dart';
import 'chips.dart';
import 'scan_screen.dart';
import 'secret_copy.dart';
import 'speed_test_sheet.dart';

/// How the list is ordered.
enum ServerSort {
  name,
  latency;

  String label(AppLocalizations l10n) => switch (this) {
    ServerSort.name => l10n.sortByName,
    ServerSort.latency => l10n.sortByLatency,
  };
}

/// Server list, plus the ways servers get in: a pasted link, a QR code, a
/// subscription, or hand-written JSON.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key});

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  @override
  void initState() {
    super.initState();
    // The service writes these at most every thirty seconds, so they are re-read
    // when the list is opened rather than polled while it is not.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) TunnelScope.read(context).refreshServerUsage();
    });
  }

  String _query = '';
  ServerSort _sort = ServerSort.name;

  // What the list showed last, and what it was built from. A latency reading
  // arriving rebuilds this screen, and re-filtering and re-sorting every server on
  // each one was work that changed nothing.
  List<_Group> _shown = const [];
  List<Outbound>? _shownFrom;
  String? _shownQuery;
  ServerSort? _shownSort;
  String? _shownSources;

  /// Groups folded shut, by subscription id ('' for the hand-added ones). Held for as
  /// long as the screen is, which is the app's: the shell keeps its tabs alive.
  final _collapsed = <String>{};

  /// Subscriptions being refreshed from their heading.
  final _refreshing = <String>{};

  Future<void> _refreshFromHeading(TunnelController controller, Subscription subscription) async {
    setState(() => _refreshing.add(subscription.id));
    try {
      // Failures are reported by the controller, as for the sheet's refresh button.
      await controller.refreshSubscription(subscription);
    } finally {
      if (mounted) setState(() => _refreshing.remove(subscription.id));
    }
  }

  /// Readings that arrived while the latency order was held; see [_visible].
  Map<String, OutboundItem>? _heldLatency;
  Timer? _settle;

  /// Fingers on the list, and whether it is still moving under its own momentum.
  int _pointers = 0;
  bool _scrolling = false;

  /// How long readings have to stop arriving before the order is settled.
  static const _settleAfter = Duration(milliseconds: 1500);

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  /// Below this a search box is clutter; above it, scrolling blind is the only
  /// alternative. Subscriptions routinely carry fifty or more.
  static const _searchThreshold = 8;

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    // Latency results and the live selection are republished once a second while
    // connected, on their own notifier. Listening to it here keeps that traffic out
    // of the rest of the app, and holding still while another tab is showing keeps it
    // out of this one.
    return VisibleListenableBuilder(
      listenable: controller.groupsChanged,
      builder: (context) => _body(context, controller),
    );
  }

  Widget _body(BuildContext context, TunnelController controller) {
    final l10n = AppLocalizations.of(context);
    final all = controller.servers;
    final latency = controller.latency;
    final groups = _visible(all, latency, controller.subscriptions);
    final selectedTag = controller.selected?.tag;
    final activeTag = controller.activeTag;

    Widget tile(Outbound server) => _ServerTile(
      server: server,
      selected: selectedTag == server.tag,
      // What is actually carrying traffic, which after a live switch is the more
      // useful thing to show.
      active: activeTag == server.tag,
      // The map built once above, not `controller.latency` -- reading that getter per
      // row rebuilt the whole map per row.
      latency: latency[server.tag],
      measured: controller.measuredLatency[server.tag],
      reachability: controller.reachability[server.tag],
      // Read from the running config rather than guessed at: one instance of each
      // other core runs, so a second server of the same kind is not in the group and
      // has nothing to be measured against.
      unmeasurable: controller.status.stage.isActive && !latency.containsKey(server.tag),
      usage: controller.serverUsage[server.tag],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.serversTitle),
        actions: [
          // Two questions, and the core can only answer one of them. Its measurement
          // takes a whole group and nothing smaller, so "the one I am on" is measured
          // through the tunnel from here instead — which is also the only way to get a
          // reading for a server running on another core, since one of those is only
          // ever in the config while it is the one in use.
          PopupMenuButton<_TestAction>(
            icon: controller.isTesting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bolt),
            // Measuring is done through the running tunnel, so there is nothing to
            // test while it is down.
            tooltip: controller.status.stage.isActive
                ? l10n.testLatency
                : l10n.testLatencyNeedsConnection,
            // Enabled whatever the tunnel is doing: one of the three works without it,
            // and a button that cannot be opened cannot say which.
            enabled: !controller.isTesting && !controller.isProbing,
            onSelected: (action) => switch (action) {
              _TestAction.inUse => controller.testActiveLatency(),
              _TestAction.everyServer => controller.testLatency(),
              _TestAction.reachability => controller.probeReachability(),
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _TestAction.inUse,
                enabled: controller.status.stage.isActive,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.my_location),
                  title: Text(l10n.testSelectedServer),
                ),
              ),
              PopupMenuItem(
                value: _TestAction.everyServer,
                enabled: controller.status.stage.isActive,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bolt),
                  title: Text(l10n.testAllServers),
                ),
              ),
              // The one that does not need the tunnel. It measures something else —
              // how long the server's address takes to accept a connection — so it is
              // its own item rather than a silent fallback for the one above.
              PopupMenuItem(
                value: _TestAction.reachability,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.network_ping),
                  title: Text(l10n.checkReachability),
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.speed),
            tooltip: l10n.speedTest,
            onPressed: controller.status.stage.isActive ? () => showSpeedTest(context) : null,
          ),
          if (all.length > 1)
            PopupMenuButton<ServerSort>(
              icon: const Icon(Icons.sort),
              tooltip: l10n.sort,
              initialValue: _sort,
              onSelected: (value) => setState(() => _sort = value),
              itemBuilder: (context) => [
                for (final sort in ServerSort.values)
                  PopupMenuItem(value: sort, child: Text(sort.label(l10n))),
              ],
            ),
          if (controller.subscriptions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.cloud_sync_outlined),
              tooltip: l10n.subscriptions,
              onPressed: () => _showSubscriptions(context),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSheet(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.actionAdd),
      ),
      body: AdaptiveBody(
        child: Column(
          children: [
            if (controller.needsReimport) const _ReimportBanner(),
            if (all.length >= _searchThreshold)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: SearchBar(
                  hintText: l10n.searchServers(all.length),
                  leading: const Icon(Icons.search),
                  onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
                ),
              ),
            Expanded(
              child: all.isEmpty
                  ? _EmptyState(l10n)
                  : groups.isEmpty
                  ? _NoMatches(l10n)
                  : RefreshIndicator(
                      // The gesture people already try on a list that can go stale. It
                      // does what the subscriptions sheet's refresh button does, so a
                      // profile with no subscriptions has nothing to pull for and the
                      // indicator settles again immediately rather than pretending.
                      onRefresh: controller.refreshAllSubscriptions,
                      child: _touchAware(
                        CustomScrollView(
                          slivers: [
                            SliverPadding(
                              // The system navigation bar is behind the body only in the
                              // rail layout; with a bottom bar the Scaffold has already
                              // taken it out, and this adds nothing.
                              padding: EdgeInsets.fromLTRB(
                                12,
                                8,
                                12,
                                bottomInset(context, extra: 96),
                              ),
                              sliver: SliverMainAxisGroup(
                                slivers: [
                                  for (final group in groups)
                                    _groupSlivers(context, controller, group, selectedTag, tile),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// One group: its heading, and its rows unless it is folded.
  ///
  /// A group of its own, so the heading is pinned only while its rows are on screen
  /// and the next group's heading pushes it off. A search unfolds everything: a match
  /// hidden inside a folded group would read as no match at all.
  Widget _groupSlivers(
    BuildContext context,
    TunnelController controller,
    _Group group,
    String? selectedTag,
    Widget Function(Outbound) tile,
  ) {
    final key = group.subscription?.id ?? '';
    final folded = group.headed && _query.isEmpty && _collapsed.contains(key);
    final subscription = group.subscription;
    return SliverMainAxisGroup(
      slivers: [
        if (group.headed)
          PinnedHeaderSliver(
            child: _GroupHeader(
              title: subscription?.name ?? AppLocalizations.of(context).serversAddedManually,
              count: group.servers.length,
              folded: folded,
              holdsSelected: group.servers.any((s) => s.tag == selectedTag),
              onToggle: _query.isEmpty
                  ? () => setState(
                      () => _collapsed.contains(key) ? _collapsed.remove(key) : _collapsed.add(key),
                    )
                  : null,
              refreshing: subscription != null && _refreshing.contains(subscription.id),
              onRefresh: subscription == null
                  ? null
                  : () => _refreshFromHeading(controller, subscription),
              onRemove: subscription == null
                  ? null
                  : () => _confirmRemoveSubscription(context, controller, subscription),
            ),
          ),
        SliverList.builder(
          itemCount: folded ? 0 : group.servers.length,
          itemBuilder: (context, index) => tile(group.servers[index]),
        ),
      ],
    );
  }

  /// The list as shown: filtered by the query, in the chosen order.
  ///
  /// Built again only when the servers, the query or the order change. Under the
  /// latency order, new readings alone do not move anything at once: during a test
  /// they land one server at a time, and re-sorting on each slid rows out from under
  /// the user's finger, so a tap meant for one server selected whichever had just
  /// moved into its place. The order is held until readings stop arriving and nobody
  /// is touching the list, then settled in one move. The figures on each row update
  /// as they come either way.
  List<_Group> _visible(
    List<Outbound> servers,
    Map<String, OutboundItem> latency,
    List<Subscription> subscriptions,
  ) {
    // The getter hands out a fresh view on every call, so the headings are compared by
    // what they show rather than by identity.
    final sources = [for (final s in subscriptions) '${s.id}\u0000${s.name}'].join('\u0001');
    final inputsChanged =
        !identical(servers, _shownFrom) ||
        _query != _shownQuery ||
        _sort != _shownSort ||
        sources != _shownSources;
    if (!inputsChanged) {
      if (_sort == ServerSort.latency && !identical(latency, _heldLatency)) {
        _heldLatency = latency;
        _settle?.cancel();
        _settle = Timer(_settleAfter, _resort);
      }
      return _shown;
    }
    _settle?.cancel();
    _heldLatency = latency;
    _shownFrom = servers;
    _shownQuery = _query;
    _shownSort = _sort;
    _shownSources = sources;
    return _shown = _grouped(_ordered(servers, latency, subscriptions), subscriptions);
  }

  /// Splits the ordered list by where each server came from: the ones added by hand
  /// first, then one group per subscription in the order they were added. Each group
  /// keeps the chosen order, and a group with nothing in it is left out.
  ///
  /// Without subscriptions there is nothing to tell apart, and a lone heading over
  /// the whole list would say nothing, so it stays one plain list.
  static List<_Group> _grouped(List<Outbound> ordered, List<Subscription> subscriptions) {
    if (subscriptions.isEmpty) {
      return [if (ordered.isNotEmpty) _Group(servers: ordered, headed: false)];
    }
    final byId = <String?, List<Outbound>>{};
    final known = {for (final s in subscriptions) s.id};
    for (final server in ordered) {
      // One naming a subscription that no longer exists stays in sight, with the
      // servers that belong to none.
      final id = known.contains(server.subscriptionId) ? server.subscriptionId : null;
      (byId[id] ??= []).add(server);
    }
    return [
      if (byId[null] case final manual?) _Group(servers: manual),
      for (final s in subscriptions)
        if (byId[s.id] case final servers?) _Group(servers: servers, subscription: s),
    ];
  }

  void _resort() {
    if (!mounted) return;
    if (_pointers > 0 || _scrolling) {
      _settle = Timer(_settleAfter, _resort);
      return;
    }
    // Dropping the cache key is enough: the next build sorts with what is current.
    setState(() => _shownFrom = null);
  }

  /// Filters and sorts. Each name is lowercased once rather than on every
  /// comparison, which for a few hundred servers was thousands of throwaway strings.
  ///
  /// Servers never measured sort last under Latency rather than first: a delay of
  /// zero means "not tested", and letting those float to the top would present
  /// untested servers as the fastest ones.
  List<Outbound> _ordered(
    List<Outbound> servers,
    Map<String, OutboundItem> latency,
    List<Subscription> subscriptions,
  ) {
    final names = {for (final s in servers) s.tag: s.tag.toLowerCase()};
    // A subscription's name finds all of its servers: it is the one name people
    // remember for a provider whose servers are called "SG-03".
    final sources = {for (final s in subscriptions) s.id: s.name.toLowerCase()};
    final filtered = _query.isEmpty
        ? [...servers]
        : servers
              .where(
                (s) =>
                    names[s.tag]!.contains(_query) ||
                    (sources[s.subscriptionId]?.contains(_query) ?? false) ||
                    s.server.toLowerCase().contains(_query) ||
                    s.type.toLowerCase().contains(_query),
              )
              .toList();

    switch (_sort) {
      case ServerSort.name:
        filtered.sort((a, b) => names[a.tag]!.compareTo(names[b.tag]!));
      case ServerSort.latency:
        int rank(Outbound server) {
          final item = latency[server.tag];
          if (item == null || !item.isMeasured) return 1 << 30;
          return item.isReachable ? item.delayMs : (1 << 30) - 1;
        }

        final ranks = {for (final s in filtered) s.tag: rank(s)};
        filtered.sort((a, b) {
          final byDelay = ranks[a.tag]!.compareTo(ranks[b.tag]!);
          return byDelay != 0 ? byDelay : names[a.tag]!.compareTo(names[b.tag]!);
        });
    }
    return filtered;
  }

  /// Tracks whether the list is being touched or is still moving, so a held order
  /// is never settled under someone's finger.
  Widget _touchAware(Widget list) => Listener(
    onPointerDown: (_) => _pointers++,
    onPointerUp: (_) => _pointers = (_pointers - 1).clamp(0, 1 << 20),
    onPointerCancel: (_) => _pointers = (_pointers - 1).clamp(0, 1 << 20),
    child: NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) _scrolling = true;
        if (notification is ScrollEndNotification) _scrolling = false;
        return false;
      },
      child: list,
    ),
  );

  static void _showAddSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _AddSheet(),
    );
  }

  static void _showSubscriptions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _SubscriptionSheet(),
    );
  }
}

/// Servers that came from one place: a subscription, or the user's own hand when
/// [subscription] is null.
class _Group {
  const _Group({required this.servers, this.subscription, this.headed = true});

  final List<Outbound> servers;
  final Subscription? subscription;

  /// False only for the plain list of a profile with no subscriptions.
  final bool headed;
}

/// Names a group by where its servers came from, and how many there are.
///
/// Pinned while its group is on screen: a subscription can carry a few hundred
/// servers, and halfway down them nothing else in view says whose they are. Tapping it
/// folds the group away; a subscription's heading also refreshes it.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    required this.folded,
    required this.holdsSelected,
    required this.onToggle,
    required this.refreshing,
    required this.onRefresh,
    required this.onRemove,
  });

  final String title;
  final int count;
  final bool folded;

  /// Whether the chosen server is in here. Shown only while folded, when the row
  /// that would otherwise say so is out of sight.
  final bool holdsSelected;

  /// Null while searching, when nothing folds.
  final VoidCallback? onToggle;
  final bool refreshing;

  /// Null for the hand-added group, which has nothing to refresh from.
  final VoidCallback? onRefresh;

  /// Null for the hand-added group too: its servers are removed one by one.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      // Opaque, because the rows scroll underneath it while it is pinned.
      color: theme.scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                expanded: onToggle == null ? null : !folded,
                label: '$title, ${l10n.serverCount(count)}',
                excludeSemantics: true,
                child: InkWell(
                  onTap: onToggle,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: folded ? -0.25 : 0,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            Icons.expand_more,
                            size: 20,
                            color: onToggle == null ? scheme.outline : scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary),
                          ),
                        ),
                        if (folded && holdsSelected) ...[
                          Icon(Icons.check_circle, size: 16, color: scheme.primary),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          '$count',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (onRefresh != null)
              refreshing
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: l10n.actionRefresh,
                      onPressed: onRefresh,
                    ),
            // Behind a menu, as on a server row, and not a bare icon beside refresh:
            // one stray tap there would offer to take every server of the group away.
            if (onRemove case final remove?)
              PopupMenuButton<VoidCallback>(
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (action) => action(),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: remove,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.delete_outline),
                      title: Text(l10n.actionRemove),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.selected,
    required this.active,
    required this.latency,
    required this.measured,
    required this.reachability,
    required this.unmeasurable,
    required this.usage,
  });

  final Outbound server;
  final bool selected;
  final bool active;
  final OutboundItem? latency;

  /// A round trip taken through the tunnel, for the server actually in use. Shown in
  /// preference to the core's: it is the path the traffic takes.
  final Duration? measured;

  /// Time to open a TCP connection to the server's own address, when that has been
  /// measured. Shown only where there is nothing better: it is the distance to the
  /// address, not a round trip through the proxy.
  final Duration? reachability;

  /// True when the core cannot include this server in a group at all.
  final bool unmeasurable;

  /// Lifetime traffic, or null for a server that has not carried any.
  final ServerUsage? usage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: active || selected ? scheme.secondaryContainer : null,
      child: ListTile(
        // Announces "selected" in the reader's own language, on the same node as the
        // tap. Until now the chosen server was marked by a container colour and a
        // check icon, and a screen reader can see neither. selectedColor is pinned to
        // the colour the title already resolves to, so this changes nothing visually.
        selected: selected,
        selectedColor: scheme.onSurface,
        leading: CircleAvatar(
          backgroundColor: selected ? scheme.primary : scheme.surfaceContainerHighest,
          child: Icon(
            !server.isUsable
                ? Icons.warning_amber_rounded
                : (selected ? Icons.check : Icons.lan_outlined),
            size: 20,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
        title: Text(server.tag, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${server.displayType.toUpperCase()} · ${server.server}:${server.serverPort}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              semanticsLabel:
                  '${server.displayType.toUpperCase()}, ${server.server}:${server.serverPort}',
            ),
            // Lifetime, not this session: the counters on the connect screen reset at
            // every reconnect, which is too often to answer "how much have I used
            // this one".
            if (usage case final usage? when usage.total > 0)
              _Note(
                icon: Icons.swap_vert,
                color: scheme.onSurfaceVariant,
                text:
                    '${formatBytes(usage.total)}'
                    '  ↓ ${formatBytes(usage.download)}  ↑ ${formatBytes(usage.upload)}',
                // Three byte counts in a row, told apart only by two arrows a screen
                // reader does not read out.
                semanticsLabel:
                    '${l10n.totalTraffic(formatBytes(usage.total))}, '
                    '${l10n.download} ${formatBytes(usage.download)}, '
                    '${l10n.upload} ${formatBytes(usage.upload)}',
              ),
            if (!server.isUsable)
              _Note(icon: Icons.block, color: scheme.error, text: server.unsupported.first)
            else if (server.requiresXray)
              _Note(icon: Icons.bolt, color: scheme.tertiary, text: l10n.runsOnXray)
            else if (server.requiresAmnezia)
              _Note(icon: Icons.bolt, color: scheme.tertiary, text: l10n.runsOnAmnezia),
            // Loud, because nothing else about a server configured this way looks
            // wrong: it connects, it carries traffic, and it is twenty times slower
            // than it should be for a reason no counter in the app reports.
            if (server.amneziaConf case final conf? when amneziaObfuscationLoss(conf) >= 0.001)
              _Note(
                icon: Icons.warning_amber_rounded,
                color: scheme.error,
                text: l10n.amneziaLossyObfuscation(
                  '${(amneziaObfuscationLoss(conf) * 100).toStringAsFixed(1)}%',
                ),
              ),
            if (unmeasurable)
              _Note(icon: Icons.speed, color: scheme.onSurfaceVariant, text: l10n.notMeasurableNow)
            // Said only when it would explain a blank the user just asked to fill.
            else if (!server.reachableOverTcp && latency == null && measured == null)
              _Note(
                icon: Icons.network_ping,
                color: scheme.onSurfaceVariant,
                text: l10n.reachabilityNeedsCore,
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (measured case final measured?)
              Text(
                '${measured.inMilliseconds} ms',
                style: TextStyle(
                  fontSize: 12,
                  color: latencyColor(scheme, measured.inMilliseconds),
                  fontWeight: FontWeight.w500,
                ),
              )
            else if (latency != null)
              LatencyChip(item: latency!)
            else if (reachability case final reachability?)
              Text(
                '${reachability.inMilliseconds} ms',
                style: TextStyle(
                  fontSize: 12,
                  color: latencyColor(scheme, reachability.inMilliseconds),
                  fontStyle: FontStyle.italic,
                ),
              ),
            // Behind a menu rather than a bare icon: removing a server is one tap
            // from a scrolling list, and copying its link needed somewhere to live.
            PopupMenuButton<_ServerAction>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) => _act(context, action),
              itemBuilder: (context) => [
                // Absent when there is nothing to copy: a custom outbound pasted as
                // JSON never had a link, and neither did anything saved before the
                // app started keeping them.
                if (server.link case final link? when link.trim().isNotEmpty)
                  PopupMenuItem(
                    value: _ServerAction.copyLink,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.link),
                      title: Text(l10n.copyLink),
                    ),
                  ),
                PopupMenuItem(
                  value: _ServerAction.remove,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_outline),
                    title: Text(l10n.actionRemove),
                  ),
                ),
              ],
            ),
          ],
        ),
        // Switches the live tunnel where possible, reconnecting only when it must.
        onTap: () => TunnelScope.read(context).switchTo(server),
      ),
    );
  }
}

enum _TestAction { inUse, everyServer, reachability }

enum _ServerAction { copyLink, remove }

extension on _ServerTile {
  Future<void> _act(BuildContext context, _ServerAction action) async {
    final controller = TunnelScope.read(context);
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case _ServerAction.copyLink:
        // The link is the server's credentials, so it goes out flagged as a secret.
        await copySecret(context, server.link!);
      case _ServerAction.remove:
        final index = await controller.removeServer(server);
        // Undo rather than a confirmation dialog: removing one server is cheap to
        // reverse, and a dialog on every removal costs the many people who meant it
        // a tap to spare the few who did not.
        if (index < 0) return;
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(l10n.serverRemoved(server.tag)),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: l10n.actionUndo,
                onPressed: () => controller.restoreServer(server, index),
              ),
            ),
          );
    }
  }
}

/// Shown once for profiles saved before share links were retained.
///
/// Those servers still work on sing-box, but the app cannot tell which of them need
/// the Xray core, because the parameter that decides it was dropped at import time.
/// Refreshing re-reads the links and restores that.
class _ReimportBanner extends StatefulWidget {
  const _ReimportBanner();

  @override
  State<_ReimportBanner> createState() => _ReimportBannerState();
}

class _ReimportBannerState extends State<_ReimportBanner> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.reimportBanner, style: TextStyle(color: scheme.onTertiaryContainer)),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => TunnelScope.read(context).dismissReimportNotice(),
                  child: Text(AppLocalizations.of(context).actionDismiss),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await TunnelScope.read(context).refreshAllSubscriptions();
                          if (mounted) setState(() => _busy = false);
                        },
                  child: _busy
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(AppLocalizations.of(context).actionRefreshAll),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A one-line annotation under a server's address.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.color, required this.text, this.semanticsLabel});

  final IconData icon;
  final Color color;
  final String text;

  /// What to say instead of [text], for notes whose written form leans on symbols.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: color),
              maxLines: 2,
              semanticsLabel: semanticsLabel,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when a search matches nothing, which is different from having no servers.
class _NoMatches extends StatelessWidget {
  const _NoMatches(this.l10n);

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        l10n.serversNoMatches,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState(this.l10n);

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(l10n.serversEmptyTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              l10n.serversEmptyBody,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddSheet extends StatefulWidget {
  const _AddSheet();

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _linkController = TextEditingController();
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _jsonController = TextEditingController();
  final _jsonNameController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _tabs.dispose();
    _linkController.dispose();
    _urlController.dispose();
    _nameController.dispose();
    _jsonController.dispose();
    _jsonNameController.dispose();
    super.dispose();
  }

  Future<void> _scanInto(TextEditingController target) async {
    final result = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (result != null && mounted) target.text = result;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    await action();
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      // Keeps the fields above the keyboard.
      padding: EdgeInsets.only(bottom: sheetInset(context)),
      child: SizedBox(
        // Fixed height overflows a short screen once the keyboard is up, and a sheet
        // that overflows clips its own submit button.
        height: (MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom - 140)
            .clamp(260.0, 420.0),
        child: Column(
          children: [
            TabBar(
              controller: _tabs,
              tabs: [
                Tab(text: l10n.tabShareLink),
                Tab(text: l10n.tabSubscription),
                Tab(text: l10n.tabJson),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _pane(
                    children: [
                      TextField(
                        controller: _linkController,
                        maxLines: 4,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: l10n.fieldShareLink,
                          hintText: 'vless:// · vmess:// · trojan:// · ss:// · hysteria2:// · tuic://\nanytls:// · socks:// · wireguard:// · or a WireGuard .conf',
                          alignLabelWithHint: true,
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            tooltip: l10n.scanQrCode,
                            onPressed: () => _scanInto(_linkController),
                          ),
                        ),
                      ),
                    ],
                    action: l10n.actionAddServer,
                    onSubmit: () =>
                        _run(() => TunnelScope.read(context).addFromLink(_linkController.text)),
                  ),
                  _pane(
                    children: [
                      TextField(
                        controller: _urlController,
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          labelText: l10n.fieldSubscriptionUrl,
                          hintText: 'https://…',
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            tooltip: l10n.scanQrCode,
                            onPressed: () => _scanInto(_urlController),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _nameController,
                        decoration: InputDecoration(labelText: l10n.fieldNameOptional),
                      ),
                    ],
                    action: l10n.actionImport,
                    onSubmit: () => _run(
                      () => TunnelScope.read(context).importSubscription(
                        name: _nameController.text.trim(),
                        url: _urlController.text.trim(),
                      ),
                    ),
                  ),
                  _pane(
                    children: [
                      TextField(
                        controller: _jsonController,
                        maxLines: 8,
                        autocorrect: false,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        decoration: InputDecoration(
                          labelText: l10n.fieldOutboundJson,
                          hintText: '{"type": "vless", "server": "...", ...}',
                          alignLabelWithHint: true,
                          helperText: l10n.outboundJsonHelp,
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _jsonNameController,
                        decoration: InputDecoration(labelText: l10n.fieldNameOptional),
                      ),
                    ],
                    action: l10n.actionAddServer,
                    onSubmit: () => _run(
                      () => TunnelScope.read(context)
                          .addCustomOutbound(_jsonController.text, name: _jsonNameController.text),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pane({
    required List<Widget> children,
    required String action,
    required VoidCallback onSubmit,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...children,
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : onSubmit,
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(action),
          ),
        ],
      ),
    );
  }
}

/// Removing a subscription takes every server it imported with it, so unlike a
/// single server this asks first: the undo would have to restore a list rather than
/// a row, and the count is the part that makes the cost obvious.
Future<void> _confirmRemoveSubscription(
  BuildContext context,
  TunnelController controller,
  Subscription sub,
) async {
  final l10n = AppLocalizations.of(context);
  final count = controller.servers.where((s) => s.subscriptionId == sub.id).length;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.removeSubscriptionTitle(sub.name)),
      content: Text(l10n.removeSubscriptionBody(count)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.actionRemove),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await controller.removeSubscription(sub);
}

class _SubscriptionSheet extends StatelessWidget {
  const _SubscriptionSheet();

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.only(bottom: sheetInset(context, extra: 24)),
      children: [
        for (final Subscription sub in controller.subscriptions)
          ListTile(
            isThreeLine: !sub.usage.isEmpty,
            leading: const Icon(Icons.cloud_outlined),
            title: Text(sub.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sub.updatedAt == null
                      ? sub.url
                      : '${l10n.updatedAgo(_ago(l10n, sub.updatedAt!))} · ${_hostOf(sub.url)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!sub.usage.isEmpty) _Quota(usage: sub.usage),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: l10n.actionRefresh,
                  onPressed: () => controller.refreshSubscription(sub),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l10n.actionRemove,
                  onPressed: () => _confirmRemoveSubscription(context, controller, sub),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _hostOf(String url) => Uri.tryParse(url)?.host ?? url;

  static String _ago(AppLocalizations l10n, DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return l10n.agoJustNow;
    if (diff.inHours < 1) return l10n.agoMinutes(diff.inMinutes);
    if (diff.inDays < 1) return l10n.agoHours(diff.inHours);
    return l10n.agoDays(diff.inDays);
  }
}

/// Quota and expiry as the provider reported them.
///
/// Only what was actually reported is shown. Providers pick and choose which fields
/// they send, and inventing a zero for a missing one would read as "no data left".
class _Quota extends StatelessWidget {
  const _Quota({required this.usage});

  final SubscriptionUsage usage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final fraction = usage.fraction;
    final days = usage.daysLeft;

    final parts = <String>[
      if (usage.used case final used?)
        usage.total == null
            ? formatBytes(used)
            : l10n.quotaUsedOf(formatBytes(used), formatBytes(usage.total!)),
      if (days != null) days < 0 ? l10n.quotaExpired : l10n.quotaExpiresIn(days),
    ];

    // Red once nearly spent, or inside the last week — the two moments worth noticing.
    final urgent = (fraction != null && fraction > 0.9) || (days != null && days <= 7);

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (fraction != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 5,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: urgent ? scheme.error : scheme.primary,
                ),
              ),
            ),
          if (parts.isNotEmpty)
            Text(
              parts.join(' · '),
              style: TextStyle(
                fontSize: 12,
                color: urgent ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
