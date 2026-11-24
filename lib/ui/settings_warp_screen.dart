import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'error_text.dart';
import 'settings_widgets.dart';

/// Cloudflare WARP: a free exit the app registers for on the user's behalf.
///
/// Lived at the top of the rules screen until the settings were split up, where it
/// was the first thing the reader had to scroll past to reach the rules they came
/// for, despite having nothing to do with them.
class WarpSettingsScreen extends StatelessWidget {
  const WarpSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final routing = controller.routing;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.sectionWarp)),
      body: ListView(
        padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
        children: [
          SwitchListTile(
            value: routing.hasWarp,
            title: Text(l10n.enableWarp),
            subtitle: Text(
              controller.isRegisteringWarp
                  ? l10n.warpRegistering
                  : routing.hasWarp
                  ? l10n.warpRegistered
                  : l10n.warpOffBody,
            ),
            secondary: controller.isRegisteringWarp
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_outlined),
            onChanged: controller.isRegisteringWarp
                ? null
                : (value) => value ? controller.enableWarp() : controller.disableWarp(),
          ),
          if (routing.hasWarp) ...[
            SwitchListTile(
              value: routing.warpThroughProxy,
              title: Text(l10n.warpThroughProxy),
              subtitle: Text(
                routing.warpThroughProxy ? l10n.warpThroughProxyOn : l10n.warpThroughProxyOff,
              ),
              secondary: const Icon(Icons.alt_route),
              onChanged: controller.setWarpThroughProxy,
            ),
            SwitchListTile(
              value: routing.warpForAll,
              title: Text(l10n.warpForAll),
              subtitle: Text(routing.warpForAll ? l10n.warpForAllOn : l10n.warpForAllOff),
              secondary: const Icon(Icons.public),
              onChanged: controller.setWarpForAll,
            ),
            SettingsTile(
              icon: Icons.vpn_key_outlined,
              title: l10n.warpLicense,
              subtitle: routing.warp!.licensed ? l10n.warpLicenseActive : l10n.warpLicenseNotSet,
              onTap: () => _applyLicense(context),
            ),
            const Divider(height: 32),
            SettingsTile(
              icon: Icons.dns_outlined,
              title: l10n.warpEndpoint,
              subtitle: routing.warpEndpoint.isEmpty ? l10n.warpEndpointAuto : routing.warpEndpoint,
              onTap: () async {
                final value = await promptText(
                  context,
                  title: l10n.warpEndpoint,
                  initial: routing.warpEndpoint,
                  helper: l10n.warpEndpointBody,
                  hint: l10n.warpEndpointAuto,
                  // Empty puts it back to whatever registration handed out.
                  validate: (value) =>
                      value.isEmpty || !value.contains(' ') ? null : l10n.invalidValue,
                );
                if (value == null || !context.mounted) return;
                await TunnelScope.read(context).setWarpEndpoint(host: value);
              },
            ),
            SettingsTile(
              icon: Icons.numbers,
              title: l10n.warpPort,
              subtitle: routing.warpPort > 0 ? '${routing.warpPort}' : l10n.warpEndpointAuto,
              onTap: () async {
                final value = await promptText(
                  context,
                  title: l10n.warpPort,
                  initial: routing.warpPort > 0 ? '${routing.warpPort}' : '',
                  hint: l10n.warpEndpointAuto,
                  keyboardType: TextInputType.number,
                  validate: (text) {
                    if (text.isEmpty) return null;
                    final port = int.tryParse(text);
                    return port != null && port > 0 && port <= 65535 ? null : l10n.invalidValue;
                  },
                );
                if (value == null || !context.mounted) return;
                await TunnelScope.read(context)
                    .setWarpEndpoint(port: value.isEmpty ? 0 : int.parse(value));
              },
            ),
          ],
        ],
      ),
    );
  }

  /// Asks for the key, then reports the outcome where the user is looking.
  ///
  /// Cloudflare's own wording is repeated verbatim on a refusal: a key can be
  /// mistyped, already bound to another device, or simply spent, and only it knows
  /// which.
  static Future<void> _applyLicense(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final controller = TunnelScope.read(context);
    final key = await promptText(
      context,
      title: l10n.warpLicense,
      initial: '',
      helper: l10n.warpLicenseBody,
      validate: (value) => value.isEmpty ? l10n.invalidValue : null,
    );
    if (key == null || key.isEmpty || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final error = await controller.applyWarpLicense(key);
    messenger.showSnackBar(
      SnackBar(
        content: Text(error == null ? l10n.warpLicenseApplied : describeError(l10n, error)),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: error != null,
      ),
    );
  }
}
