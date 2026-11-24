import 'package:flutter/material.dart';

import '../core/profile/routing.dart';
import '../l10n/app_localizations.dart';
import 'l10n_ext.dart';
import '../main.dart';
import 'app_shell.dart';

/// Presets and hand-written rules, in the order the core evaluates them.
class RoutingScreen extends StatelessWidget {
  const RoutingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final routing = controller.routing;
    final unavailable = controller.unavailablePresets.map((e) => e.id).toSet();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.routingTitle),
        actions: [
          _UpdateListsButton(
            updating: controller.isUpdatingRuleSets,
            onPressed: () => _updateLists(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showRuleSheet(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.addRule),
      ),
      body: AdaptiveBody(
        child: RefreshIndicator(
          // Same job as the button in the app bar. The lists behind these presets are
          // downloaded files that go stale, and pulling is what people try first.
          onRefresh: () => controller.refreshRuleSets(force: true),
          child: ListView(
            // AlwaysScrollable so the gesture still works when the rules fit on screen.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(bottom: bottomInset(context, extra: 96)),
            children: [
              _Header(l10n.sectionPresets),
              for (final preset in RuleSetPreset.catalog)
                SwitchListTile(
                  value: routing.enabledPresets.contains(preset.id),
                  title: Text(preset.label),
                  subtitle: Text(
                    unavailable.contains(preset.id) ? l10n.presetUnavailable : preset.description,
                    style: unavailable.contains(preset.id)
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                  secondary: Icon(
                    preset.action == RuleAction.block ? Icons.block : Icons.call_split,
                  ),
                  onChanged: (value) => controller.togglePreset(preset, value),
                ),
              const Divider(height: 32),
              _Header(l10n.sectionMyRules),
              if (routing.rules.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(l10n.myRulesHint),
                ),
              for (final (index, rule) in routing.rules.indexed)
                Dismissible(
                  key: ValueKey('$index-${rule.match.name}-${rule.value}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    // Directional, not centerRight: in Arabic and Farsi the swipe runs the
                    // other way, and the icon has to sit at the end the row leaves behind.
                    alignment: AlignmentDirectional.centerEnd,
                    padding: const EdgeInsetsDirectional.only(end: 24),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: const Icon(Icons.delete_outline),
                  ),
                  // A swipe is easy to start by accident while scrolling, and a rule holds
                  // typing nobody wants to repeat -- so the removal is offered back.
                  onDismissed: (_) {
                    controller.removeRuleAt(index);
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(l10n.ruleRemoved),
                          behavior: SnackBarBehavior.floating,
                          action: SnackBarAction(
                            label: l10n.actionUndo,
                            onPressed: () => controller.restoreRuleAt(index, rule),
                          ),
                        ),
                      );
                  },
                  child: CheckboxListTile(
                    value: rule.enabled,
                    title: Text(rule.value),
                    // A rule that no longer validates is skipped when the config is
                    // built. Saying so here is the only place it can be noticed: the
                    // tunnel starts fine and the rule simply never fires.
                    subtitle: Text(
                      rule.isValid
                          ? '${rule.match.label(l10n)} → ${rule.action.label(l10n)}'
                                '${rule.server == null ? '' : ' · ${rule.server}'}'
                          : '${rule.match.label(l10n)} — ${l10n.ruleInvalid}',
                      style: rule.isValid
                          ? null
                          : TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                    secondary: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l10n.editRule,
                      onPressed: () => _showRuleSheet(context, index: index, existing: rule),
                    ),
                    onChanged: (value) => controller.toggleRuleAt(index, value ?? true),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// One sheet for both jobs. [index] and [existing] are null when adding.
  static void _showRuleSheet(BuildContext context, {int? index, RoutingRule? existing}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RuleSheet(index: index, existing: existing),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _RuleSheet extends StatefulWidget {
  const _RuleSheet({this.index, this.existing});

  /// Position of the rule being edited, or null when adding a new one.
  final int? index;
  final RoutingRule? existing;

  @override
  State<_RuleSheet> createState() => _RuleSheetState();
}

class _RuleSheetState extends State<_RuleSheet> {
  late final TextEditingController _value = TextEditingController(
    text: widget.existing?.value ?? '',
  );
  late RuleMatch _match = widget.existing?.match ?? RuleMatch.domainSuffix;
  late RuleAction _action = widget.existing?.action ?? RuleAction.direct;

  /// For a proxy rule: the server it goes through, or null for the selected one.
  late String? _server = widget.existing?.server;

  /// Only shown once a save has been attempted. Marking a field red before the
  /// user has finished typing in it is noise.
  bool _submitted = false;

  bool get _isEditing => widget.index != null;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  /// Fields with a closed set start on their first value rather than empty, so the
  /// picker never shows a blank selection.
  void _onMatchChanged(RuleMatch match) {
    setState(() {
      _match = match;
      final choices = match.choices;
      if (choices != null && !choices.contains(_value.text.trim().toLowerCase())) {
        _value.text = choices.first;
      }
    });
  }

  void _save() {
    final value = _value.text.trim();
    if (!_match.isValid(value)) {
      setState(() => _submitted = true);
      return;
    }
    final rule = RoutingRule(
      match: _match,
      value: value,
      action: _action,
      server: _server,
      // Editing keeps whatever the rule's switch was set to.
      enabled: widget.existing?.enabled ?? true,
    );
    final controller = TunnelScope.read(context);
    if (widget.index case final index?) {
      controller.updateRuleAt(index, rule);
    } else {
      controller.addRule(rule);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final hasWarp = controller.routing.hasWarp;
    final l10n = AppLocalizations.of(context);
    final choices = _match.choices;
    final invalid = _submitted && !_match.isValid(_value.text.trim());

    return Padding(
      padding: EdgeInsets.only(bottom: sheetInset(context)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<RuleMatch>(
              initialValue: _match,
              decoration: InputDecoration(labelText: l10n.matchOn),
              items: [
                for (final match in RuleMatch.values)
                  DropdownMenuItem(value: match, child: Text(match.label(l10n))),
              ],
              onChanged: (value) => _onMatchChanged(value ?? _match),
            ),
            const SizedBox(height: 12),
            // A closed set gets a picker, not a text box: `protocol: htp` is valid
            // JSON that matches nothing, and nothing about the result says why.
            if (choices != null)
              DropdownButtonFormField<String>(
                initialValue: choices.contains(_value.text.trim().toLowerCase())
                    ? _value.text.trim().toLowerCase()
                    : choices.first,
                decoration: InputDecoration(labelText: l10n.value),
                items: [
                  for (final choice in choices)
                    DropdownMenuItem(value: choice, child: Text(choice)),
                ],
                onChanged: (value) => setState(() => _value.text = value ?? choices.first),
              )
            else
              TextField(
                controller: _value,
                autocorrect: false,
                keyboardType: _match.isNumeric ? TextInputType.number : TextInputType.text,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l10n.value,
                  hintText: _match.hint(l10n),
                  errorText: invalid ? l10n.invalidValue : null,
                  helperText: invalid ? null : _match.hint(l10n),
                  helperMaxLines: 2,
                ),
              ),
            // Sniffing is what produces the protocol name in the first place. A
            // protocol rule written with it off is a rule that can never fire.
            if (_match.needsSniffing && !controller.settings.sniffing)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      size: 20,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.protocolNeedsSniffing,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            SegmentedButton<RuleAction>(
              segments: [
                // WARP only appears once an account exists; a rule pointing at an
                // outbound that is not in the config would stop the tunnel starting.
                for (final action in RuleAction.values)
                  if (action != RuleAction.warp || hasWarp)
                    ButtonSegment(value: action, label: Text(action.label(l10n))),
              ],
              selected: {_action},
              onSelectionChanged: (value) => setState(() => _action = value.first),
            ),
            // Which server "Proxy" means for this rule: a site that only works from
            // one country can go through that country's server while everything else
            // stays on the one selected.
            if (_action == RuleAction.proxy) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: controller.servers.any((s) => s.tag == _server) ? _server : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: l10n.ruleServer),
                items: [
                  DropdownMenuItem(value: null, child: Text(l10n.ruleServerSelected)),
                  for (final server in controller.servers)
                    if (server.isUsable)
                      DropdownMenuItem(
                        value: server.tag,
                        child: Text(server.tag, overflow: TextOverflow.ellipsis),
                      ),
                ],
                onChanged: (value) => setState(() => _server = value),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(onPressed: _save, child: Text(_isEditing ? l10n.saveRule : l10n.addRule)),
          ],
        ),
      ),
    );
  }
}

/// Downloads every enabled list again, and says so while it happens.
///
/// The spinning icon is the whole story on the screen itself; the messages are for
/// the case where it is not being watched — a download over a slow link takes long
/// enough to put the phone down over.
Future<void> _updateLists(BuildContext context) async {
  final controller = TunnelScope.read(context);
  // Tapping again mid-download would start a second set of requests for the same
  // files. The icon is left enabled rather than greyed, because a faded spinner
  // reads as broken.
  if (controller.isUpdatingRuleSets) return;
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);

  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(l10n.updatingLists),
      behavior: SnackBarBehavior.floating,
      // Outlives any plausible download; it is taken down by hand below rather than
      // by a timer, so the message and the spinner always end together.
      duration: const Duration(minutes: 5),
    ),
  );

  await controller.refreshRuleSets(force: true);

  messenger.hideCurrentSnackBar();
  // A list that could not be downloaded raises its own message, and "updated" on top
  // of that would contradict it.
  if (controller.unavailablePresets.isEmpty) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.listsUpdated), behavior: SnackBarBehavior.floating),
    );
  }
}

/// The refresh action, turning while any rule set is downloading.
///
/// It turns for downloads it did not start too — enabling a preset and connecting
/// both fetch lists — because the question it answers is whether the app is busy
/// fetching, not whether this button was the thing that asked.
class _UpdateListsButton extends StatefulWidget {
  const _UpdateListsButton({required this.updating, required this.onPressed});

  final bool updating;
  final VoidCallback onPressed;

  @override
  State<_UpdateListsButton> createState() => _UpdateListsButtonState();
}

class _UpdateListsButtonState extends State<_UpdateListsButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    // Already running when this screen is opened mid-download, which happens on the
    // refresh that connecting starts.
    if (widget.updating) _turns.repeat();
  }

  @override
  void didUpdateWidget(_UpdateListsButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.updating == oldWidget.updating) return;
    if (widget.updating) {
      _turns.repeat();
    } else {
      // Finishes the turn it is on instead of stopping at whatever angle the last
      // frame left it, which on an icon whose meaning is rotation reads as a fault.
      _turns.forward().whenCompleteOrCancel(() {
        // Not if another download started inside the settle: that one is turning
        // from wherever it began, and resetting under it would be a visible jump.
        if (mounted && !_turns.isAnimating) _turns.value = 0;
      });
    }
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IconButton(
      icon: RotationTransition(turns: _turns, child: const Icon(Icons.refresh)),
      tooltip: widget.updating ? l10n.updatingLists : l10n.updateLists,
      onPressed: widget.onPressed,
    );
  }
}
