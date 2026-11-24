import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../main.dart';
import 'word_safe_text.dart';

/// A settings row that opens something else.
///
/// The subtitle is the current value wherever there is one. A settings list whose
/// rows only say what they are called makes the reader open every one of them to
/// find the setting they came for.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.description,
    this.enabled = true,
  });

  final IconData icon;
  final String title;

  /// The current value, in the reader's own terms.
  final String subtitle;

  /// What the setting does, for the rows whose name does not already say.
  ///
  /// A row that shows only its value answers "what is this set to" and leaves
  /// "what is this" unanswered — which for something like an interval is the
  /// question the reader actually arrived with. Rendered under the value rather
  /// than replacing it, because both are wanted at once.
  final String? description;

  final VoidCallback? onTap;

  /// Greys the row out and stops it opening, for a setting whose parent switch is
  /// off. Shown rather than hidden: a row that disappears takes the explanation of
  /// what the switch above controls with it.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      enabled: enabled,
      leading: Icon(icon),
      title: WordSafeText(title),
      isThreeLine: description != null,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          WordSafeText(subtitle),
          if (description case final text?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                text,
                // A row is a row. Capped so a translation that runs long cannot turn
                // one setting into half a screenful.
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// Picks one of [options]. Returns null when dismissed.
///
/// [label] renders each option, so callers can pass raw config values and still show
/// something readable.
Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required T current,
  required String Function(T value) label,
  String Function(T value)? describe,
}) => showDialog<T>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text(title),
    children: [
      RadioGroup<T>(
        groupValue: current,
        onChanged: (value) => Navigator.of(context).pop(value),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              RadioListTile<T>(
                value: option,
                title: Text(label(option)),
                subtitle: describe == null ? null : Text(describe(option)),
              ),
          ],
        ),
      ),
    ],
  ),
);

/// Asks for a value in a text field. Returns null when dismissed or invalid.
///
/// [validate] returns null when the text is acceptable, or the reason it is not —
/// shown under the field rather than swallowed, because a rejected value that simply
/// does not take is indistinguishable from a setting that does not work.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String initial,
  String? helper,
  String? hint,
  TextInputType? keyboardType,
  String? Function(String value)? validate,
}) {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController(text: initial);
  final error = ValueNotifier<String?>(null);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ValueListenableBuilder<String?>(
        valueListenable: error,
        builder: (context, message, _) => TextField(
          controller: controller,
          autofocus: true,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            helperText: helper,
            helperMaxLines: 3,
            hintText: hint,
            errorText: message,
            errorMaxLines: 2,
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.actionCancel)),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            final problem = validate?.call(value);
            if (problem != null) {
              error.value = problem;
              return;
            }
            Navigator.of(context).pop(value);
          },
          child: Text(l10n.actionSave),
        ),
      ],
    ),
  ).whenComplete(() {
    controller.dispose();
    error.dispose();
  });
}

/// Language names in their own script, never translated.
///
/// Someone hunting for their language is, by definition, looking at a UI they cannot
/// read — "Persian" is no help to a Persian speaker who has landed in Chinese.
const _languageNames = <String, String>{
  'en': 'English',
  'id': 'Bahasa Indonesia',
  'zh': '中文',
  'fa': 'فارسی',
  'ru': 'Русский',
  'ar': 'العربية',
  'vi': 'Tiếng Việt',
  'tr': 'Türkçe',
};

String languageLabel(AppLocalizations l10n, String? code) =>
    // Null is a real choice, not a missing one: follow whatever the device is set to.
    code == null ? l10n.languageSystem : (_languageNames[code] ?? code);

Future<void> pickLanguage(BuildContext context, String? current) async {
  final controller = TunnelScope.read(context);
  final l10n = AppLocalizations.of(context);
  final codes = AppLocalizations.supportedLocales.map((e) => e.languageCode).toList()
    ..sort((a, b) => (_languageNames[a] ?? a).compareTo(_languageNames[b] ?? b));

  final choice = await showDialog<String?>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l10n.language),
      children: [
        RadioGroup<String?>(
          groupValue: current,
          onChanged: (value) => Navigator.of(context).pop(value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String?>(value: null, title: Text(l10n.languageSystem)),
              for (final code in codes)
                RadioListTile<String?>(value: code, title: Text(_languageNames[code] ?? code)),
            ],
          ),
        ),
      ],
    ),
  );
  if (choice != current) await controller.setLocale(choice);
}
