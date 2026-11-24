import 'package:flutter/material.dart';

import '../core/profile/server_export.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'error_text.dart';
import 'secret_copy.dart';

/// Export and restore everything the app knows: servers, subscriptions, routing
/// rules and settings.
///
/// The backup is one line of text, so it can go wherever the user keeps things: a
/// file through the system picker, which reaches cloud drives as easily as the phone,
/// or the clipboard, for a note or a password manager. Neither needs a storage
/// permission. It is always encrypted, because it carries every server's credentials
/// and those places are rarely private.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _exportPassword = TextEditingController();
  final _exportRepeat = TextEditingController();
  final _importPassword = TextEditingController();
  final _importData = TextEditingController();

  String? _exported;

  /// A backup read from a file. Held here rather than put into the text field: a
  /// large backup laid out as text costs far more than it shows anyone.
  String? _fromFile;

  bool _showPasswords = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A backup made under one password and shown beside a field now holding another
    // is a backup someone will save believing it opens with the new one.
    void forgetExport() {
      if (_exported != null) setState(() => _exported = null);
    }

    _exportPassword.addListener(forgetExport);
    _exportRepeat.addListener(forgetExport);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _exportPassword.dispose();
    _exportRepeat.dispose();
    _importPassword.dispose();
    _importData.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);
    final password = _exportPassword.text;
    if (password.length < 8) {
      setState(() => _error = l10n.backupPasswordTooShort);
      return;
    }
    // Typed twice because a typo here is not caught until the day the backup is
    // needed, and then there is no way back in.
    if (_exportRepeat.text != password) {
      setState(() => _error = l10n.backupPasswordMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await TunnelScope.read(context).exportBackup(password);
      if (mounted) setState(() => _exported = result);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveFile(String backup) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    try {
      final saved = await TunnelScope.read(context).channel
          .saveTextFile(name: 'trefoil-backup-$date.txt', text: backup);
      if (!saved) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.backupSaved), behavior: SnackBarBehavior.floating),
      );
    } catch (e) {
      if (mounted) setState(() => _error = describeError(l10n, e));
    }
  }

  Future<void> _openFile() async {
    final l10n = AppLocalizations.of(context);
    try {
      final text = await TunnelScope.read(context).channel.openTextFile();
      if (text == null || !mounted) return;
      setState(() {
        _fromFile = text.trim();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeError(l10n, e));
    }
  }

  Future<void> _import() async {
    final l10n = AppLocalizations.of(context);
    // Asked before rather than undone after: what is here now is gone once the backup
    // is in its place.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.backupReplaceTitle),
        content: Text(l10n.backupReplaceBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.backupRestore),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TunnelScope.read(context)
          .importBackup(_fromFile ?? _importData.text, _importPassword.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.backupRestored), behavior: SnackBarBehavior.floating),
      );
    } catch (e) {
      if (mounted) setState(() => _error = describeError(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.backupTitle),
        bottom: TabBar(
          controller: _tabs,
          onTap: (_) => setState(() => _error = null),
          tabs: [
            Tab(text: l10n.backupTabExport),
            Tab(text: l10n.backupTabRestore),
          ],
        ),
      ),
      body: TabBarView(controller: _tabs, children: [_exportTab(context), _importTab(context)]),
    );
  }

  Widget _passwordField(
    TextEditingController controller,
    String label, {
    String? helper,
    bool toggle = false,
  }) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      controller: controller,
      obscureText: !_showPasswords,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        // One switch reveals both fields: comparing them by eye is the point.
        suffixIcon: toggle
            ? IconButton(
                tooltip: _showPasswords ? l10n.hidePassword : l10n.showPassword,
                icon: Icon(_showPasswords ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showPasswords = !_showPasswords),
              )
            : null,
      ),
    );
  }

  Widget _errorLine(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
  );

  static const _spinner = SizedBox(
    height: 18,
    width: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );

  Widget _exportTab(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottomInset(context, extra: 20)),
      children: [
        Text(l10n.backupExportBody),
        const SizedBox(height: 16),
        _passwordField(
          _exportPassword,
          l10n.backupPassword,
          helper: l10n.backupPasswordHelp,
          toggle: true,
        ),
        const SizedBox(height: 12),
        _passwordField(_exportRepeat, l10n.backupPasswordRepeat),
        if (_error != null) _errorLine(context),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _export,
          child: _busy ? _spinner : Text(l10n.backupCreate),
        ),
        if (_exported case final backup?) ...[
          const SizedBox(height: 16),
          Card.filled(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock_outline, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.backupReady, style: theme.textTheme.titleSmall),
                            Text(
                              l10n.backupCharacters(backup.length),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () => _saveFile(backup),
                    icon: const Icon(Icons.save_alt),
                    label: Text(l10n.backupSaveFile),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => copySecret(context, backup, confirmation: l10n.backupCopied),
                    icon: const Icon(Icons.copy),
                    label: Text(l10n.backupCopy),
                  ),
                ],
              ),
            ),
          ),
        ],
        // A second, lesser export, kept on the same screen because this is where
        // someone comes when they are moving to another phone. The encrypted backup
        // above carries everything and only this app can read it; this carries the
        // servers alone, in a format anything can.
        const Divider(height: 40),
        Text(
          l10n.exportServers,
          style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.exportServersBody,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: TunnelScope.of(context).servers.isEmpty ? null : _exportServers,
          icon: const Icon(Icons.playlist_add_check),
          label: Text(l10n.actionCopy),
        ),
      ],
    );
  }

  Future<void> _exportServers() async {
    final l10n = AppLocalizations.of(context);
    final export = ServerExport.of(TunnelScope.read(context).servers);
    // The skipped count is reported rather than swallowed: restoring onto a new
    // phone and finding servers missing, with nothing having said so, is worse than
    // the export being incomplete in the first place.
    final summary = [
      l10n.exportServersDone(export.exported),
      if (export.skipped > 0) l10n.exportServersSkipped(export.skipped),
    ].join(' · ');
    if (export.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(summary)));
      return;
    }
    // Share links are the servers' credentials, unencrypted: flagged as a secret.
    await copySecret(context, export.body, confirmation: summary);
  }

  Widget _importTab(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final fromFile = _fromFile;
    final ready = (fromFile ?? _importData.text).trim().isNotEmpty;
    return ListView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottomInset(context, extra: 20)),
      children: [
        Text(l10n.backupRestoreBody),
        const SizedBox(height: 16),
        if (fromFile == null) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _openFile,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(l10n.backupOpenFile),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _importData,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: l10n.backupText, alignLabelWithHint: true),
          ),
        ] else
          Card.outlined(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.description_outlined, color: theme.colorScheme.primary),
              title: Text(l10n.backupFromFile),
              subtitle: Text(l10n.backupCharacters(fromFile.length)),
              trailing: IconButton(
                tooltip: l10n.backupRemoveFile,
                icon: const Icon(Icons.close),
                onPressed: _busy ? null : () => setState(() => _fromFile = null),
              ),
            ),
          ),
        const SizedBox(height: 12),
        _passwordField(_importPassword, l10n.backupPassword, toggle: true),
        if (_error != null) _errorLine(context),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || !ready ? null : _import,
          child: _busy ? _spinner : Text(l10n.backupRestore),
        ),
      ],
    );
  }
}
