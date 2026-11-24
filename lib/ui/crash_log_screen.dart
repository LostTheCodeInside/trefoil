import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/crash_log.dart';
import '../l10n/app_localizations.dart';
import 'app_shell.dart';

/// The crash log, as recorded on this device.
///
/// There is no server behind this and no upload button. Copying it out is the whole
/// mechanism: the user reads what happened and decides for themselves whether any of
/// it goes anywhere.
class CrashLogScreen extends StatefulWidget {
  const CrashLogScreen({super.key});

  @override
  State<CrashLogScreen> createState() => _CrashLogScreenState();
}

class _CrashLogScreenState extends State<CrashLogScreen> {
  late Future<String> _log = CrashLog.instance.read();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.crashReportsView),
        actions: [
          FutureBuilder<String>(
            future: _log,
            builder: (context, snapshot) {
              final text = snapshot.data ?? '';
              return Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy_all_outlined),
                    tooltip: l10n.actionCopy,
                    onPressed: text.isEmpty ? null : () => _copy(context, text),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l10n.actionClear,
                    onPressed: text.isEmpty ? null : _clear,
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _log,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.crashReportsEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            );
          }
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset(context, extra: 16)),
            child: SelectableText(
              snapshot.data!,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
            ),
          );
        },
      ),
    );
  }

  Future<void> _clear() async {
    await CrashLog.instance.clear();
    if (!mounted) return;
    setState(() => _log = CrashLog.instance.read());
  }

  static Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).copied),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
