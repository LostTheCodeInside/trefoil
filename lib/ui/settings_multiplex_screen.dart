import 'package:flutter/material.dart';

import '../core/profile/multiplex.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'settings_widgets.dart';
import 'word_safe_text.dart';

/// Carrying many streams over one connection.
///
/// The warning sits above the switch rather than below it because the failure mode
/// is the quiet kind: a server that does not speak the protocol does not refuse,
/// it stops answering, and that is indistinguishable from a blocked server. Someone
/// who turned this on and forgot needs to be able to find their way back.
class MultiplexSettingsScreen extends StatelessWidget {
  const MultiplexSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = controller.settings;
    final mux = settings.multiplex;

    Future<void> update(MultiplexSettings value) =>
        TunnelScope.read(context).updateSettings(settings.copyWith(multiplex: value));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.multiplex)),
      body: ListView(
        padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
        children: [
          _Note(icon: Icons.info_outline, text: l10n.multiplexScope),
          SwitchListTile(
            value: mux.enabled,
            secondary: const Icon(Icons.merge_type),
            title: WordSafeText(l10n.enableMultiplex),
            subtitle: Text(l10n.multiplexBenefit),
            onChanged: (value) => update(mux.copyWith(enabled: value)),
          ),
          if (mux.enabled)
            _Note(
              icon: Icons.warning_amber_outlined,
              text: l10n.multiplexServerAgrees,
              tone: _Tone.caution,
            ),
          SettingsTile(
            icon: Icons.hub_outlined,
            title: l10n.multiplexProtocol,
            subtitle: mux.protocol,
            enabled: mux.enabled,
            onTap: () async {
              final choice = await pickOption<String>(
                context,
                title: l10n.multiplexProtocol,
                options: MultiplexSettings.protocols,
                current: mux.protocol,
                label: (value) => value,
              );
              if (choice != null) await update(mux.copyWith(protocol: choice));
            },
          ),
          SettingsTile(
            icon: Icons.stacked_line_chart,
            title: l10n.multiplexStreams,
            subtitle: '${mux.maxStreams}',
            description: l10n.multiplexStreamsBody,
            enabled: mux.enabled,
            onTap: () async {
              final entered = await promptText(
                context,
                title: l10n.multiplexStreams,
                initial: '${mux.maxStreams}',
                keyboardType: TextInputType.number,
                validate: (value) {
                  final parsed = int.tryParse(value.trim());
                  return parsed != null && MultiplexSettings.isValidStreamCount(parsed)
                      ? null
                      : l10n.invalidValue;
                },
              );
              if (entered != null) {
                await update(mux.copyWith(maxStreams: int.parse(entered.trim())));
              }
            },
          ),
          SwitchListTile(
            value: mux.padding,
            secondary: const Icon(Icons.blur_on),
            title: Text(l10n.multiplexPadding),
            subtitle: Text(l10n.multiplexPaddingBody),
            onChanged: mux.enabled ? (value) => update(mux.copyWith(padding: value)) : null,
          ),
        ],
      ),
    );
  }
}

enum _Tone { info, caution }

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.tone = _Tone.info});

  final IconData icon;
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = tone == _Tone.caution
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final foreground = tone == _Tone.caution ? scheme.onErrorContainer : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text, style: TextStyle(color: foreground)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
