import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/tunnel_controller.dart';
import '../core/tunnel_status.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'connections_screen.dart';

/// Live core log. The first place to look when a connection "succeeds" but nothing
/// loads, which is why it is a top-level destination rather than buried in settings.
class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    // Log lines arrive in bursts -- hundreds a second while a tunnel comes up -- so
    // they are published on their own notifier. This screen is the only listener,
    // which is what stops a chatty core from rebuilding the rest of the app.
    return ListenableBuilder(
      listenable: controller.logsChanged,
      builder: (context, _) => _body(context, controller),
    );
  }

  Widget _body(BuildContext context, TunnelController controller) {
    final l10n = AppLocalizations.of(context);
    final logs = controller.logs;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.logsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.hub_outlined),
            tooltip: l10n.connectionsTitle,
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const ConnectionsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: l10n.logsCopy,
            onPressed: logs.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(text: logs.map((e) => e.message).join('\n')),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.logsCopied), behavior: SnackBarBehavior.floating),
                    );
                  },
          ),
        ],
      ),
      body: logs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  controller.status.stage.isActive ? l10n.logsWaiting : l10n.logsIdle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.fromLTRB(12, 8, 12, bottomInset(context, extra: 8)),
              // Newest first: the interesting line is almost always the last one,
              // and this avoids fighting the scroll position on every new batch.
              reverse: true,
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final entry = logs[logs.length - 1 - index];
                return _LogLine(entry: entry);
              },
            ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final CoreLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        entry.message,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.35,
          color: entry.isError ? scheme.error : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
