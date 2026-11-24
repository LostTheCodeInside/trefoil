import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../core/profile/routing.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'about_screen.dart';
import 'app_shell.dart';
import 'backup_screen.dart';
import 'config_screen.dart';
import 'logs_screen.dart';
import 'settings_dns_screen.dart';
import 'settings_general_screen.dart';
import 'settings_inbound_screen.dart';
import 'settings_multiplex_screen.dart';
import 'settings_routing_screen.dart';
import 'settings_tls_screen.dart';
import 'settings_warp_screen.dart';
import 'settings_widgets.dart';
import 'usage_screen.dart';

/// The way in to every setting, one subject per row.
///
/// This was a single list of everything, which is fine at six rows and unusable at
/// twenty: unrelated switches sat between the two halves of one subject, and finding
/// anything meant scrolling past all of it. Each row here names its subject and
/// carries its current state as the subtitle, so the answer to "where is X" and
/// "what is X set to" are both on this screen.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = controller.settings;

    void open(Widget screen) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: AdaptiveBody(
        child: ListView(
          padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
          children: [
            SettingsTile(
              icon: Icons.tune,
              title: l10n.settingsGeneral,
              subtitle: l10n.settingsGeneralBody,
              onTap: () => open(const GeneralSettingsScreen()),
            ),
            SettingsTile(
              icon: Icons.alt_route,
              title: l10n.sectionRouting,
              subtitle: routingSummary(l10n, settings.routing),
              onTap: () => open(const RoutingSettingsScreen()),
            ),
            SettingsTile(
              icon: Icons.dns_outlined,
              title: l10n.settingsDns,
              subtitle: settings.remoteDns,
              onTap: () => open(const DnsSettingsScreen()),
            ),
            SettingsTile(
              icon: Icons.input,
              title: l10n.settingsInbound,
              subtitle: '${settings.tunStack} · MTU ${settings.mtu}',
              onTap: () => open(const InboundSettingsScreen()),
            ),
            SettingsTile(
              icon: Icons.merge_type,
              title: l10n.multiplex,
              subtitle: settings.multiplex.enabled
                  ? '${settings.multiplex.protocol} · ${settings.multiplex.maxStreams}'
                  : l10n.multiplexBody,
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const MultiplexSettingsScreen())),
            ),
            SettingsTile(
              icon: Icons.content_cut,
              title: l10n.tlsTricks,
              subtitle: settings.tlsTricks.isActive ? l10n.enableFragment : l10n.tlsTricksBody,
              onTap: () => open(const TlsSettingsScreen()),
            ),
            SettingsTile(
              icon: Icons.cloud_outlined,
              title: l10n.sectionWarp,
              subtitle: settings.routing.hasWarp ? l10n.warpRegistered : l10n.settingsWarpBody,
              onTap: () => open(const WarpSettingsScreen()),
            ),
            const Divider(height: 32),
            SettingsTile(
              icon: Icons.article_outlined,
              title: l10n.navLogs,
              subtitle: l10n.settingsLogsBody,
              onTap: () => open(const LogsScreen()),
            ),
            SettingsTile(
              icon: Icons.data_usage,
              title: l10n.dataUsage,
              subtitle: l10n.dataUsageBody,
              onTap: () => open(const UsageScreen()),
            ),
            SettingsTile(
              icon: Icons.backup_outlined,
              title: l10n.backup,
              subtitle: l10n.backupBody,
              onTap: () => open(const BackupScreen()),
            ),
            SettingsTile(
              icon: Icons.data_object,
              title: l10n.generatedConfig,
              subtitle: l10n.generatedConfigBody,
              onTap: () => open(const ConfigScreen()),
            ),
            const Divider(height: 32),
            // Says so here when a newer build is waiting, which is where the badge on
            // the Settings destination leads.
            ListenableBuilder(
              listenable: AppUpdater.instance,
              builder: (context, _) => SettingsTile(
                icon: Icons.info_outline,
                title: l10n.sectionAbout,
                subtitle: switch (AppUpdater.instance) {
                  final updater when updater.stage == UpdateStage.available => l10n.appUpdateSnack(
                    updater.update?.versionName ?? '',
                  ),
                  _ => l10n.settingsAboutBody,
                },
                onTap: () => open(const AboutScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared with the routing screen, which shows the same summary one level down.
String routingSummary(AppLocalizations l10n, RoutingSettings routing) {
  final presets = routing.enabledPresets.length;
  final rules = routing.rules.where((r) => r.enabled).length;
  if (presets == 0 && rules == 0) return l10n.rulesSummaryNone;
  return l10n.rulesSummary(presets, rules);
}
