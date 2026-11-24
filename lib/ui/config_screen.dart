import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';

/// Shows the sing-box config the selected server actually runs.
///
/// A proxy client that cannot show its own generated config is undebuggable: when a
/// handshake fails there is no way to tell a bad share link from a bad server without
/// this. Copying redacts credentials so the config can be pasted into a bug report.
class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  late final Future<String> _config = TunnelScope.read(context).generatedConfig();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.configTitle),
        actions: [
          FutureBuilder<String>(
            future: _config,
            builder: (context, snapshot) => IconButton(
              icon: const Icon(Icons.copy_all_outlined),
              tooltip: l10n.configCopyRedacted,
              onPressed: snapshot.data == null || snapshot.data!.isEmpty
                  ? null
                  : () => _copyRedacted(context, snapshot.data!),
            ),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _config,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(l10n.configSelectServer, textAlign: TextAlign.center),
              ),
            );
          }
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset(context, extra: 16)),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                snapshot.data!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
              ),
            ),
          );
        },
      ),
    );
  }

  static Future<void> _copyRedacted(BuildContext context, String config) async {
    await Clipboard.setData(ClipboardData(text: redactSecrets(config)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).configCopied),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Replaces credential values with a placeholder, leaving the structure intact.
///
/// `public_key` and `short_id` are deliberately kept: they are not secret, and they
/// are exactly the fields a REALITY handshake failure turns on.
String redactSecrets(String config) {
  const secretKeys = {'uuid', 'password', 'private_key', 'pre_shared_key', 'secret'};
  try {
    final decoded = jsonDecode(config);
    return const JsonEncoder.withIndent('  ').convert(_redact(decoded, secretKeys));
  } catch (_) {
    return config;
  }
}

Object? _redact(Object? node, Set<String> secretKeys) {
  if (node is Map) {
    return {
      for (final entry in node.entries)
        entry.key: secretKeys.contains(entry.key) ? '***' : _redact(entry.value, secretKeys),
    };
  }
  if (node is List) return node.map((e) => _redact(e, secretKeys)).toList();
  return node;
}
