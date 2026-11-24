import 'package:flutter/material.dart';

import '../core/tunnel_channel.dart';
import '../core/tunnel_status.dart';
import '../l10n/app_localizations.dart';
import 'app_icon.dart';
import 'app_shell.dart';

/// What the tunnel is carrying right now, and through which outbound.
///
/// The outbound column is the fastest way to confirm a routing rule is doing what
/// you meant: a domain you sent direct should say `direct`, not `proxy`.
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  /// Package name to the name a person would recognise.
  ///
  /// Asked for once, and only here: the core reports the package that opened a
  /// connection, which is the right thing to route on and the wrong thing to read.
  /// The list renders straight away with whatever it has and picks the names up when
  /// they arrive — a moment later, and only the first time the screen is opened.
  Map<String, String> _labels = const {};

  @override
  void initState() {
    super.initState();
    TunnelChannel.instance
        .installedApps()
        .then((apps) {
          if (!mounted) return;
          setState(() => _labels = {for (final app in apps) app.packageName: app.label});
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.connectionsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: l10n.connectionsCloseAll,
            onPressed: () => TunnelChannel.instance.closeConnections(),
          ),
        ],
      ),
      body: StreamBuilder<List<ActiveConnection>>(
        stream: TunnelChannel.instance.connections,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _Empty(l10n.connectionsNeedsConnection);
          }
          final items = snapshot.data;
          if (items == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return _Empty(l10n.connectionsEmpty);
          }
          return AdaptiveBody(
            child: ListView.separated(
              padding: EdgeInsets.only(bottom: bottomInset(context)),
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _ConnectionTile(connection: items[index], labels: _labels),
            ),
          );
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({required this.connection, required this.labels});

  final ActiveConnection connection;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final direct = connection.outbound == 'direct';
    final package = connection.appPackage;
    // The interpunct is a visual separator. Read aloud it is either nothing or the
    // words "middle dot", so the spoken form joins on a comma, which is the pause a
    // screen reader already knows how to make.
    final parts = [
      // The label if we have one, and the package name if we do not — which is
      // still better than nothing while the labels are being looked up.
      if (package.isNotEmpty) labels[package] ?? package,
      if (connection.user.isNotEmpty) connection.user,
      connection.network.toUpperCase(),
      if (connection.protocol.isNotEmpty) connection.protocol,
    ];
    return ListTile(
      dense: true,
      // Only when the core named an app. Reserving the space regardless would put a
      // column of grey squares down a list that, for anyone not routing by app, will
      // never have an icon to put in it.
      leading: package.isEmpty ? null : AppIcon(package, size: 32),
      title: Text(connection.target, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        parts.join(' · '),
        semanticsLabel: parts.join(', '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            connection.outbound.isEmpty ? '—' : connection.outbound,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: direct ? scheme.tertiary : scheme.primary,
            ),
            semanticsLabel: connection.outbound.isEmpty ? l10n.noReadingYet : null,
          ),
          // The arrows carry the whole meaning of the two figures and a screen
          // reader does not read them, so spoken it would be two byte counts in a
          // row with no way to tell which direction either belongs to.
          Text(
            '↑${formatBytes(connection.uplink)} ↓${formatBytes(connection.downlink)}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            semanticsLabel:
                '${l10n.upload} ${formatBytes(connection.uplink)}, '
                '${l10n.download} ${formatBytes(connection.downlink)}',
          ),
        ],
      ),
      onLongPress: () => TunnelChannel.instance.closeConnection(connection.id),
    );
  }
}
