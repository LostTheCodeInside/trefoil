import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../main.dart';

/// Copies something that grants access — a server link, a backup, a password —
/// and says so.
///
/// Goes through the native side so the clip is flagged sensitive: left out of the
/// preview Android shows after a copy, and out of keyboard clipboard histories that
/// honour the flag. Where that is not available the copy still happens, unflagged:
/// refusing to copy would only send the user to a worse way of moving the text.
Future<void> copySecret(BuildContext context, String text, {String? confirmation}) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = confirmation ?? AppLocalizations.of(context).copied;
  final channel = TunnelScope.read(context).channel;
  try {
    await channel.copySensitive(text);
  } on Exception {
    await Clipboard.setData(ClipboardData(text: text));
  }
  messenger.showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}
