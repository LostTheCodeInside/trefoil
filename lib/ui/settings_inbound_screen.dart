import 'package:flutter/material.dart';

import '../core/profile/config_builder.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'secret_copy.dart';
import 'settings_widgets.dart';
import 'word_safe_text.dart';

/// The TUN device itself — how packets get from Android into the core.
class InboundSettingsScreen extends StatelessWidget {
  const InboundSettingsScreen({super.key});

  /// Below this, sing-box refuses the config; above it, Android refuses the TUN.
  static const minMtu = 1280;
  static const maxMtu = 9000;

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = controller.settings;
    final hasLocalProxy = settings.mixedPort > 0 || settings.directPort > 0;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsInbound)),
      body: ListView(
        padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
        children: [
          SettingsTile(
            icon: Icons.layers_outlined,
            title: l10n.tunStack,
            subtitle: settings.tunStack,
            description: l10n.tunStackBody,
            onTap: () async {
              final choice = await pickOption<String>(
                context,
                title: l10n.tunStack,
                options: ConfigBuilder.tunStacks,
                current: settings.tunStack,
                label: (value) => value,
              );
              if (choice == null || !context.mounted) return;
              await TunnelScope.read(context).updateSettings(settings.copyWith(tunStack: choice));
            },
          ),
          SettingsTile(
            icon: Icons.straighten,
            title: l10n.mtu,
            subtitle: '${settings.mtu}',
            onTap: () async {
              final value = await promptText(
                context,
                title: l10n.mtu,
                initial: '${settings.mtu}',
                helper: l10n.mtuBody,
                keyboardType: TextInputType.number,
                validate: (value) {
                  final parsed = int.tryParse(value);
                  // Checked here rather than left to the core: an out-of-range MTU
                  // surfaces as the tunnel refusing to start, with nothing pointing
                  // at this screen as the cause.
                  if (parsed == null || parsed < minMtu || parsed > maxMtu) {
                    return l10n.invalidValue;
                  }
                  return null;
                },
              );
              if (value == null || !context.mounted) return;
              await TunnelScope.read(context)
                  .updateSettings(settings.copyWith(mtu: int.parse(value)));
            },
          ),
          const Divider(height: 32),
          SwitchListTile(
            value: settings.strictRoute,
            secondary: const Icon(Icons.merge_type),
            title: WordSafeText(l10n.strictRoute),
            subtitle: Text(l10n.strictRouteBody),
            onChanged: (value) =>
                TunnelScope.read(context).updateSettings(settings.copyWith(strictRoute: value)),
          ),
          _PortTile(
            icon: Icons.swap_horiz,
            title: l10n.mixedPort,
            helper: l10n.mixedPortBody,
            value: settings.mixedPort,
            onChanged: (value) =>
                TunnelScope.read(context).updateSettings(settings.copyWith(mixedPort: value)),
          ),
          _PortTile(
            icon: Icons.arrow_forward,
            title: l10n.directPort,
            helper: l10n.directPortBody,
            value: settings.directPort,
            onChanged: (value) =>
                TunnelScope.read(context).updateSettings(settings.copyWith(directPort: value)),
          ),
          SwitchListTile(
            value: settings.localProxyAuth,
            secondary: const Icon(Icons.lock_outline),
            title: Text(l10n.localProxyAuth),
            subtitle: Text(l10n.localProxyAuthBody),
            // Locking the proxy takes it away from Android's system proxy, which has
            // no field for a login; the two switches say so rather than disagreeing.
            onChanged: hasLocalProxy
                ? (value) => TunnelScope.read(context).updateSettings(
                    settings.copyWith(
                      localProxyAuth: value,
                      httpProxyForVpn: value ? false : settings.httpProxyForVpn,
                    ),
                  )
                : null,
          ),
          if (hasLocalProxy && settings.localProxyLocked) ...[
            _SecretTile(
              icon: Icons.person_outline,
              title: l10n.proxyUsername,
              value: settings.localProxyUsername,
            ),
            _SecretTile(
              icon: Icons.password,
              title: l10n.proxyPassword,
              value: settings.localProxyPassword,
            ),
          ],
          SwitchListTile(
            value: settings.handsProxyToAndroid,
            secondary: const Icon(Icons.public),
            title: Text(l10n.httpProxyForVpn),
            subtitle: Text(
              settings.mixedPort <= 0
                  ? l10n.httpProxyNeedsPort
                  : settings.localProxyAuth
                  ? l10n.httpProxyNeedsOpenProxy
                  : l10n.httpProxyForVpnBody,
            ),
            // Android is handed the local proxy's port, so there has to be one — and
            // it has to answer without a login, because Android cannot give one.
            onChanged: settings.mixedPort > 0 && !settings.localProxyAuth
                ? (value) =>
                      TunnelScope.read(context)
                          .updateSettings(settings.copyWith(httpProxyForVpn: value))
                : null,
          ),
          SwitchListTile(
            value: settings.shareInLocalNetwork,
            secondary: const Icon(Icons.share),
            title: Text(l10n.shareInLocalNetwork),
            subtitle: Text(
              settings.localProxyLocked
                  ? l10n.shareInLocalNetworkLockedBody
                  : l10n.shareInLocalNetworkBody,
            ),
            // Nothing to share until one of the local proxies exists.
            onChanged: hasLocalProxy
                ? (value) =>
                      TunnelScope.read(context)
                          .updateSettings(settings.copyWith(shareInLocalNetwork: value))
                : null,
          ),
          const Divider(height: 32),
          _PortTile(
            icon: Icons.api,
            title: l10n.clashApiPort,
            helper: l10n.clashApiPortBody,
            value: settings.clashApiPort,
            onChanged: (value) {
              final controller = TunnelScope.read(context);
              // Minted on the way in, and only when there is not one already: a
              // dashboard configured against the old secret should keep working.
              final secret = settings.clashApiSecret.isEmpty
                  ? ConfigBuilder.generateApiSecret()
                  : settings.clashApiSecret;
              controller.updateSettings(
                settings.copyWith(clashApiPort: value, clashApiSecret: secret),
              );
            },
          ),
          if (settings.clashApiPort > 0 && settings.clashApiSecret.isNotEmpty)
            _SecretTile(
              icon: Icons.key,
              title: l10n.clashApiSecret,
              value: settings.clashApiSecret,
            ),
        ],
      ),
    );
  }
}

/// A credential shown in full, because it gets typed into another app, with a copy
/// that leaves it out of the clipboard preview.
class _SecretTile extends StatelessWidget {
  const _SecretTile({required this.icon, required this.title, required this.value});

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy_all_outlined),
        tooltip: AppLocalizations.of(context).actionCopy,
        onPressed: () => copySecret(context, value),
      ),
    );
  }
}

/// A port, or off. Zero is the off value everywhere this appears.
class _PortTile extends StatelessWidget {
  const _PortTile({
    required this.icon,
    required this.title,
    required this.helper,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String helper;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: value > 0 ? '$value' : l10n.portOff,
      onTap: () async {
        final entered = await promptText(
          context,
          title: title,
          initial: value > 0 ? '$value' : '',
          helper: helper,
          hint: l10n.portOff,
          keyboardType: TextInputType.number,
          validate: (text) {
            // Empty is how the user turns it off.
            if (text.isEmpty) return null;
            final port = int.tryParse(text);
            // Below 1024 needs privileges an unprivileged app does not have, and the
            // failure would surface as the tunnel refusing to start.
            if (port == null || port < 1024 || port > 65535) return l10n.invalidValue;
            return null;
          },
        );
        if (entered == null) return;
        onChanged(entered.isEmpty ? 0 : int.parse(entered));
      },
    );
  }
}
