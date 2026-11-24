import 'package:flutter/material.dart';

import '../core/profile/config_builder.dart';
import '../core/profile/routing.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'per_app_screen.dart';
import 'routing_screen.dart';
import 'settings_screen.dart';
import 'settings_widgets.dart';
import 'word_safe_text.dart';

/// What goes through the tunnel and what does not.
///
/// Everything here lives in the generated config, so it takes effect on the next
/// connect — the shell raises a reconnect prompt when one of these changes while a
/// tunnel is up.
class RoutingSettingsScreen extends StatelessWidget {
  const RoutingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = controller.settings;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.sectionRouting)),
      body: ListView(
        padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
        children: [
          SettingsTile(
            icon: Icons.apps,
            title: l10n.perAppProxy,
            subtitle: perAppSummary(l10n, settings.perApp),
            onTap: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const PerAppScreen())),
          ),
          SwitchListTile(
            value: settings.routingMode == RoutingMode.bypassLan,
            secondary: const Icon(Icons.call_split),
            title: Text(l10n.routingBypassLan),
            subtitle: Text(
              settings.routingMode == RoutingMode.bypassLan
                  ? l10n.routingBypassLanBody
                  : l10n.routingGlobalBody,
            ),
            onChanged: (value) => TunnelScope.read(context).updateSettings(
              settings.copyWith(routingMode: value ? RoutingMode.bypassLan : RoutingMode.global),
            ),
          ),
          SwitchListTile(
            value: settings.enableIpv6,
            secondary: const Icon(Icons.looks_6_outlined),
            title: Text(l10n.ipv6),
            subtitle: WordSafeText(l10n.ipv6Body),
            onChanged: (value) =>
                TunnelScope.read(context).updateSettings(settings.copyWith(enableIpv6: value)),
          ),
          SwitchListTile(
            value: settings.sniffing,
            secondary: const Icon(Icons.travel_explore),
            title: Text(l10n.sniffing),
            subtitle: WordSafeText(l10n.sniffingBody),
            onChanged: (value) =>
                TunnelScope.read(context).updateSettings(settings.copyWith(sniffing: value)),
          ),
          const Divider(height: 32),
          SettingsTile(
            icon: Icons.alt_route,
            title: l10n.rulesAndFiltering,
            subtitle: routingSummary(l10n, settings.routing),
            onTap: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const RoutingScreen())),
          ),
          SettingsTile(
            icon: Icons.cloud_download_outlined,
            title: l10n.ruleSetSource,
            subtitle: _sourceLabel(l10n, settings.routing.ruleSetSource),
            description: l10n.ruleSetSourceBody,
            onTap: () => _pickSource(context, settings.routing),
          ),
        ],
      ),
    );
  }
}

String _sourceLabel(AppLocalizations l10n, String source) => switch (source) {
  RuleSetSource.jsdelivr => l10n.ruleSetSourceJsdelivr,
  RuleSetSource.custom => l10n.ruleSetSourceCustom,
  _ => l10n.ruleSetSourceOfficial,
};

/// Picks a source, and asks for an address when that source needs one.
///
/// The re-fetch is forced by the controller: what is already on disk came from the
/// source being abandoned, and the reason to change is usually that it stopped
/// working.
Future<void> _pickSource(BuildContext context, RoutingSettings routing) async {
  final l10n = AppLocalizations.of(context);
  final controller = TunnelScope.read(context);
  final choice = await pickOption<String>(
    context,
    title: l10n.ruleSetSource,
    options: RuleSetSource.values,
    current: routing.ruleSetSource,
    label: (value) => _sourceLabel(l10n, value),
  );
  if (choice == null || !context.mounted) return;

  if (choice != RuleSetSource.custom) {
    await controller.setRuleSetSource(choice);
    return;
  }
  final base = await promptText(
    context,
    title: l10n.ruleSetBase,
    initial: routing.ruleSetBase,
    helper: l10n.ruleSetBaseBody('https://…'),
    hint: 'https://mirror.example.com',
    validate: (value) {
      final uri = Uri.tryParse(value);
      return uri != null && uri.hasScheme && uri.host.isNotEmpty ? null : l10n.invalidValue;
    },
  );
  if (base == null) return;
  await controller.setRuleSetSource(RuleSetSource.custom, base: base);
}

String perAppSummary(AppLocalizations l10n, PerAppRules rules) => switch (rules.mode) {
  PerAppMode.off => l10n.perAppAll,
  PerAppMode.include => l10n.perAppIncluded(rules.packages.length),
  PerAppMode.exclude => l10n.perAppExcluded(rules.packages.length),
};
