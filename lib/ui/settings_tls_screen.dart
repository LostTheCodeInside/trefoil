import 'package:flutter/material.dart';

import '../core/profile/xray_config.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'settings_widgets.dart';

/// Splitting the TLS handshake past a filter that reads it.
///
/// Only the Xray core can do this, and in this app Xray runs only for the VLESS
/// servers sing-box cannot handle. The banner says so up front: a switch that
/// silently does nothing for most people's servers is worse than no switch.
class TlsSettingsScreen extends StatelessWidget {
  const TlsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = controller.settings;
    final tricks = settings.tlsTricks;

    Future<void> update(TlsTricks value) =>
        TunnelScope.read(context).updateSettings(settings.copyWith(tlsTricks: value));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.tlsTricks)),
      body: ListView(
        padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l10n.fragmentXrayOnly)),
                  ],
                ),
              ),
            ),
          ),
          SwitchListTile(
            value: tricks.fragment,
            secondary: const Icon(Icons.content_cut),
            title: Text(l10n.enableFragment),
            subtitle: Text(l10n.tlsTricksBody),
            onChanged: (value) => update(tricks.copyWith(fragment: value)),
          ),
          _RangeTile(
            icon: Icons.layers_outlined,
            title: l10n.fragmentPackets,
            value: tricks.packets,
            enabled: tricks.fragment,
            // Not a range: this one names which packets, and `tlshello` is a word.
            validate: (value) => value.isEmpty ? l10n.invalidValue : null,
            onChanged: (value) => update(tricks.copyWith(packets: value)),
          ),
          _RangeTile(
            icon: Icons.straighten,
            title: l10n.fragmentLength,
            value: tricks.length,
            enabled: tricks.fragment,
            validate: (value) => TlsTricks.isValidRange(value) ? null : l10n.invalidValue,
            onChanged: (value) => update(tricks.copyWith(length: value)),
          ),
          _RangeTile(
            icon: Icons.timer_outlined,
            title: l10n.fragmentInterval,
            value: tricks.interval,
            enabled: tricks.fragment,
            validate: (value) => TlsTricks.isValidRange(value) ? null : l10n.invalidValue,
            onChanged: (value) => update(tricks.copyWith(interval: value)),
          ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              l10n.certificateSection,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          SwitchListTile(
            value: settings.allowInsecure,
            secondary: const Icon(Icons.lock_open),
            title: Text(l10n.allowInsecure),
            subtitle: Text(l10n.allowInsecureBody),
            onChanged: (value) =>
                TunnelScope.read(context).updateSettings(settings.copyWith(allowInsecure: value)),
          ),
          SwitchListTile(
            value: controller.insecureDownloads,
            secondary: const Icon(Icons.cloud_off),
            title: Text(l10n.insecureDownloads),
            subtitle: Text(l10n.insecureDownloadsBody),
            onChanged: controller.setInsecureDownloads,
          ),
          // Shown only while one of them is on: a standing warning about a state the
          // reader is not in is noise, and noise is what gets scrolled past.
          if (settings.allowInsecure || controller.insecureDownloads)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.gpp_maybe_outlined,
                        size: 20,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.insecureWarning,
                          style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RangeTile extends StatelessWidget {
  const _RangeTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.enabled,
    required this.validate,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool enabled;
  final String? Function(String value) validate;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: enabled ? null : scheme.onSurfaceVariant.withValues(alpha: 0.4)),
      title: Text(
        title,
        style: enabled ? null : TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
      ),
      subtitle: Text(value),
      enabled: enabled,
      trailing: const Icon(Icons.chevron_right),
      onTap: !enabled
          ? null
          : () async {
              final entered = await promptText(
                context,
                title: title,
                initial: value,
                validate: validate,
              );
              if (entered != null) onChanged(entered);
            },
    );
  }
}
