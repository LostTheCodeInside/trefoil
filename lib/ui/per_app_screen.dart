import 'package:flutter/material.dart';

import '../core/profile/config_builder.dart';
import '../core/tunnel_channel.dart';
import '../core/tunnel_status.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_icon.dart';
import 'app_shell.dart';

/// Chooses which apps the tunnel applies to.
///
/// Android enforces include and exclude as mutually exclusive on the VpnService
/// builder, so the mode is a single choice rather than two independent lists.
class PerAppScreen extends StatefulWidget {
  const PerAppScreen({super.key});

  @override
  State<PerAppScreen> createState() => _PerAppScreenState();
}

class _PerAppScreenState extends State<PerAppScreen> {
  late Future<List<InstalledApp>> _apps;
  late PerAppMode _mode;
  late Set<String> _selected;

  /// Which apps were ticked when the current order was worked out.
  ///
  /// Separate from [_selected] on purpose. The chosen apps sort to the top, which is
  /// the only way to see what you picked in a list four hundred rows long — but if
  /// the order followed the ticks, a row would jump to the top of the list the moment
  /// it was tapped, taking the next one you meant to tap out from under your finger.
  /// So the order is settled when the screen opens and when the search changes, and
  /// stands still while you work down it.
  late Set<String> _order;

  String _query = '';
  bool _initialised = false;

  /// Whether system apps with no launcher entry are listed. Off by default: there
  /// are hundreds and almost none matter here — but the few that do, like Google
  /// Play Services, carry real traffic and have to be reachable somehow.
  bool _showSystem = false;

  @override
  void initState() {
    super.initState();
    _apps = TunnelChannel.instance.installedApps().catchError((Object _) => <InstalledApp>[]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;
    final rules = TunnelScope.of(context).settings.perApp;
    _mode = rules.mode;
    _selected = rules.packages.toSet();
    _order = {..._selected};
  }

  void _commit() {
    final controller = TunnelScope.read(context);
    final base = controller.settings;
    controller.updateSettings(
      base.copyWith(
        perApp: PerAppRules(mode: _mode, packages: _selected.toList()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (_mode != PerAppMode.off)
            PopupMenuButton<void>(
              itemBuilder: (context) => [
                CheckedPopupMenuItem<void>(
                  checked: _showSystem,
                  onTap: () => setState(() {
                    _showSystem = !_showSystem;
                    _order = {..._selected};
                  }),
                  child: Text(l10n.appsShowSystem),
                ),
              ],
            ),
        ],
        title: _mode == PerAppMode.off
            ? Text(l10n.perAppProxy)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.perAppProxy),
                  // The count, because the answer to "how many did I pick" should
                  // not be "scroll the whole list and count them".
                  Text(
                    l10n.appsSelected(_selected.length),
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SegmentedButton<PerAppMode>(
                  segments: [
                    ButtonSegment(value: PerAppMode.off, label: Text(l10n.appsAll)),
                    ButtonSegment(value: PerAppMode.include, label: Text(l10n.appsOnlyThese)),
                    ButtonSegment(value: PerAppMode.exclude, label: Text(l10n.appsExceptThese)),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (value) {
                    setState(() {
                      _mode = value.first;
                      _order = {..._selected};
                    });
                    _commit();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: SearchBar(
                  hintText: l10n.appsSearch,
                  leading: const Icon(Icons.search),
                  onChanged: (value) => setState(() {
                    _query = value.toLowerCase();
                    _order = {..._selected};
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
      body: _mode == PerAppMode.off
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(l10n.appsAllUseTunnel, textAlign: TextAlign.center),
              ),
            )
          : FutureBuilder<List<InstalledApp>>(
              future: _apps,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final apps = snapshot.data!
                    .where(
                      (a) =>
                          // A chosen app is always shown: a selection the list hides
                          // is a selection nobody can see or undo.
                          (_showSystem || !a.isBackground || _selected.contains(a.packageName)) &&
                          (_query.isEmpty ||
                              a.label.toLowerCase().contains(_query) ||
                              a.packageName.toLowerCase().contains(_query)),
                    )
                    .toList();
                // A stable sort, so within each half the list keeps the order the
                // platform gave it — which is already by label.
                apps.sort((a, b) {
                  final chosen = _order.contains(b.packageName) ? 1 : 0;
                  return chosen - (_order.contains(a.packageName) ? 1 : 0);
                });
                if (apps.isEmpty) {
                  return Center(child: Text(l10n.appsNoMatches));
                }
                return AdaptiveBody(
                  child: ListView.builder(
                    padding: EdgeInsets.only(bottom: bottomInset(context)),
                    itemCount: apps.length,
                    itemBuilder: (context, index) {
                      final app = apps[index];
                      return CheckboxListTile(
                        // Keyed by package so filtering rebuilds a row against the app
                        // it now holds, rather than reusing the previous one's icon.
                        key: ValueKey(app.packageName),
                        value: _selected.contains(app.packageName),
                        // Leading, with the checkbox staying on the trailing edge.
                        secondary: AppIcon(app.packageName),
                        title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          app.packageName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onChanged: (checked) {
                          setState(() {
                            if (checked ?? false) {
                              _selected.add(app.packageName);
                            } else {
                              _selected.remove(app.packageName);
                            }
                          });
                          _commit();
                        },
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}
