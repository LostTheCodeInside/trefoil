import 'package:flutter/material.dart';

import '../core/profile/config_builder.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'settings_widgets.dart';

/// Which resolvers the tunnel uses, and how names turn into addresses.
class DnsSettingsScreen extends StatelessWidget {
  const DnsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = controller.settings;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsDns)),
      body: ListView(
        padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
        children: [
          SettingsTile(
            icon: Icons.dns_outlined,
            title: l10n.remoteDns,
            subtitle: settings.remoteDns,
            onTap: () async {
              final value = await promptText(
                context,
                title: l10n.remoteDns,
                initial: settings.remoteDns,
                helper: l10n.remoteDnsBody,
                hint: 'tls://1.1.1.1',
                validate: (value) => _validUrl(value) ? null : l10n.invalidValue,
              );
              if (value == null || !context.mounted) return;
              await TunnelScope.read(context).updateSettings(settings.copyWith(remoteDns: value));
            },
          ),
          SettingsTile(
            icon: Icons.travel_explore,
            title: l10n.directDns,
            // Empty is the default and the recommended one, so it gets a name rather
            // than showing as a blank row.
            subtitle: settings.directDns.isEmpty ? l10n.directDnsSystem : settings.directDns,
            onTap: () async {
              final value = await promptText(
                context,
                title: l10n.directDns,
                initial: settings.directDns,
                helper: l10n.directDnsBody,
                hint: l10n.directDnsSystem,
                // Empty is allowed on purpose: it is how the user goes back to the
                // network's own resolver.
                validate: (value) {
                  if (value.isEmpty) return null;
                  if (!_validUrl(value)) return l10n.invalidValue;
                  // This is the resolver that resolves hostnames, so a hostname here
                  // has nothing to resolve it: sing-box refuses the config and the
                  // tunnel never starts. Caught at the keyboard instead.
                  return ConfigBuilder.isIpLiteral(_hostOf(value)) ? null : l10n.directDnsMustBeIp;
                },
              );
              if (value == null || !context.mounted) return;
              await TunnelScope.read(context).updateSettings(settings.copyWith(directDns: value));
            },
          ),
          SettingsTile(
            icon: Icons.swap_horiz,
            title: l10n.domainStrategy,
            subtitle: settings.domainStrategy == ConfigBuilder.strategyAuto
                ? l10n.domainStrategyAuto
                : settings.domainStrategy,
            onTap: () async {
              final choice = await pickOption<String>(
                context,
                title: l10n.domainStrategy,
                options: ConfigBuilder.domainStrategies,
                current: settings.domainStrategy,
                label: (value) =>
                    value == ConfigBuilder.strategyAuto ? l10n.domainStrategyAuto : value,
              );
              if (choice == null || !context.mounted) return;
              await TunnelScope.read(context)
                  .updateSettings(settings.copyWith(domainStrategy: choice));
            },
          ),
          SettingsTile(
            icon: Icons.travel_explore,
            title: l10n.serverAddressStrategy,
            subtitle: settings.serverAddressStrategy == ConfigBuilder.strategyAuto
                ? l10n.domainStrategyAuto
                : settings.serverAddressStrategy,
            description: l10n.serverAddressStrategyBody,
            onTap: () async {
              final choice = await pickOption<String>(
                context,
                title: l10n.serverAddressStrategy,
                options: ConfigBuilder.domainStrategies,
                current: settings.serverAddressStrategy,
                label: (value) =>
                    value == ConfigBuilder.strategyAuto ? l10n.domainStrategyAuto : value,
              );
              if (choice == null || !context.mounted) return;
              await TunnelScope.read(context)
                  .updateSettings(settings.copyWith(serverAddressStrategy: choice));
            },
          ),
          const Divider(height: 32),
          SwitchListTile(
            value: settings.fakeDns,
            secondary: const Icon(Icons.bolt),
            title: Text(l10n.fakeDns),
            subtitle: Text(l10n.fakeDnsBody),
            onChanged: (value) =>
                TunnelScope.read(context).updateSettings(settings.copyWith(fakeDns: value)),
          ),
          SwitchListTile(
            value: settings.resolveDestination,
            secondary: const Icon(Icons.my_location),
            title: Text(l10n.resolveDestination),
            subtitle: Text(l10n.resolveDestinationBody),
            onChanged: (value) =>
                TunnelScope.read(context)
                    .updateSettings(settings.copyWith(resolveDestination: value)),
          ),
        ],
      ),
    );
  }

  /// A host, with or without a scheme. Rejects the shapes sing-box would refuse at
  /// start, which is otherwise a tunnel that simply will not come up.
  static String _hostOf(String value) {
    final uri = Uri.tryParse(value.contains('://') ? value : 'tls://$value');
    return uri == null || uri.host.isEmpty ? value : uri.host;
  }

  static bool _validUrl(String value) {
    if (value.contains(' ')) return false;
    final uri = Uri.tryParse(value.contains('://') ? value : 'tls://$value');
    return uri != null && uri.host.isNotEmpty;
  }
}
