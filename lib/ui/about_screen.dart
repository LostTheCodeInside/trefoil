import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../core/tunnel_channel.dart';
import '../l10n/app_localizations.dart';
import 'app_shell.dart';
import 'word_safe_text.dart';

/// This build, whether there is a newer one, and which cores it carries.
///
/// The core versions are read from the cores themselves rather than from a constant,
/// so this cannot claim a version the shipped binary is not.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.updater});

  /// The app's own unless a test hands one in.
  final AppUpdater? updater;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  /// Resolved once. Building this inside `build` would re-invoke the platform
  /// channel on every rebuild.
  late final Future<Map<String, String>> _versions = _coreVersions();

  late final AppUpdater _updater = widget.updater ?? AppUpdater.instance;

  /// Back from Android's "install unknown apps" page, the install carries on by itself
  /// rather than waiting for a second tap.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _updater.resume);

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _updater.loadInstalled();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sectionAbout)),
      body: FutureBuilder<Map<String, String>>(
        future: _versions,
        builder: (context, snapshot) {
          final versions = snapshot.data;
          return ListView(
            padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
            children: [
              ListenableBuilder(
                listenable: _updater,
                builder: (context, _) => _UpdateSection(updater: _updater),
              ),
              ListTile(
                leading: const Icon(Icons.memory),
                title: Text(l10n.singBoxCore),
                subtitle: Text(versions?['singBox'] ?? l10n.checking),
              ),
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: Text(l10n.xrayCore),
                subtitle: Text(
                  versions == null ? l10n.checking : l10n.xrayCoreBody(versions['xray'] ?? ''),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static Future<Map<String, String>> _coreVersions() async {
    try {
      return await TunnelChannel.instance.coreVersions();
    } on TunnelException catch (e) {
      return {'singBox': e.message, 'xray': e.message};
    }
  }
}

/// The installed version, and one button for whatever the next step is.
class _UpdateSection extends StatelessWidget {
  const _UpdateSection({required this.updater});

  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    if (!updater.supported) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final version = updater.installed?.versionName ?? '…';
    final update = updater.update;

    final (String status, Widget action) = switch (updater.stage) {
      UpdateStage.idle => (
        l10n.appVersionInstalled(version),
        TextButton(onPressed: updater.check, child: Text(l10n.appUpdateCheck)),
      ),
      UpdateStage.checking => (
        l10n.checking,
        const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      UpdateStage.upToDate => (
        l10n.appUpToDate(version),
        TextButton(onPressed: updater.check, child: Text(l10n.appUpdateCheck)),
      ),
      UpdateStage.available => (
        l10n.appUpdateAvailable(update?.versionName ?? '', formatBytes(update?.size ?? 0)),
        FilledButton.tonal(
          onPressed: updater.downloadAndInstall,
          child: Text(l10n.appUpdateInstall),
        ),
      ),
      UpdateStage.downloading => (
        l10n.appUpdateDownloading(formatBytes(updater.received), formatBytes(update?.size ?? 0)),
        TextButton(onPressed: updater.cancel, child: Text(l10n.actionCancel)),
      ),
      UpdateStage.needsPermission => (
        l10n.appUpdateNeedsPermission,
        FilledButton.tonal(
          onPressed: updater.openInstallSettings,
          child: Text(l10n.appUpdateAllow),
        ),
      ),
      // Offered again in case the system dialog went away without an answer.
      UpdateStage.installing => (
        l10n.appUpdateInstalling,
        TextButton(onPressed: updater.downloadAndInstall, child: Text(l10n.appUpdateInstall)),
      ),
      UpdateStage.failed => (
        _failure(l10n),
        TextButton(onPressed: updater.check, child: Text(l10n.actionRetry)),
      ),
    };

    final failed = updater.stage == UpdateStage.failed;
    final notes = update?.notes ?? '';
    final showNotes =
        notes.isNotEmpty &&
        const {
          UpdateStage.available,
          UpdateStage.downloading,
          UpdateStage.needsPermission,
          UpdateStage.installing,
        }.contains(updater.stage);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: WordSafeText(l10n.appUpdates),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(status, style: failed ? TextStyle(color: theme.colorScheme.error) : null),
              if (updater.stage == UpdateStage.downloading)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(value: updater.progress),
                ),
            ],
          ),
          trailing: action,
        ),
        // What the 100 MB is for, read before spending it.
        if (showNotes && update != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.appUpdateWhatsNew(update.versionName),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: SingleChildScrollView(
                        child: Text(notes, style: theme.textTheme.bodyMedium),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _failure(AppLocalizations l10n) => switch (updater.failure) {
    UpdateFailure.network => l10n.appUpdateErrorNetwork,
    UpdateFailure.server => l10n.appUpdateErrorServer(updater.failureDetail),
    UpdateFailure.malformed => l10n.appUpdateErrorMalformed,
    UpdateFailure.incomplete => l10n.appUpdateErrorIncomplete,
    UpdateFailure.signature => l10n.appUpdateErrorSignature,
    UpdateFailure.storage => l10n.appUpdateErrorStorage(updater.failureDetail),
    UpdateFailure.rejected || null => l10n.appUpdateErrorRejected(updater.failureDetail),
  };
}
