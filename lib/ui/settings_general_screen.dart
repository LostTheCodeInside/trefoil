import 'package:flutter/material.dart';

import '../core/profile/config_builder.dart';
import '../core/tunnel_channel.dart';
import '../l10n/app_localizations.dart';
import '../main.dart';
import 'app_shell.dart';
import 'crash_log_screen.dart';
import 'settings_widgets.dart';

/// How the app itself behaves: language, appearance, what it reports and whether
/// Android is allowed to put it to sleep.
///
/// Nothing here reaches the generated config, which is why none of it needs a
/// reconnect — except the log level, which does.
class GeneralSettingsScreen extends StatefulWidget {
  const GeneralSettingsScreen({super.key});

  @override
  State<GeneralSettingsScreen> createState() => _GeneralSettingsScreenState();
}

class _GeneralSettingsScreenState extends State<GeneralSettingsScreen> with WidgetsBindingObserver {
  bool _autoStart = false;
  AlwaysOnStatus _alwaysOn = const AlwaysOnStatus();
  String _notificationSpeed = NotificationSpeed.total;
  bool _batteryOptimized = false;
  bool _memoryLimit = false;
  bool _debugMode = false;
  bool _metered = false;
  bool _wakeLock = false;
  bool _trafficStats = true;
  bool _resetOnNetworkChange = false;
  bool _resetOnWake = false;
  bool _groupInNotification = false;
  int _notificationInterval = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The battery exemption is granted in the system settings, so the answer changes
    // while this screen is in the background. Re-reading on return is what stops the
    // row from still claiming the app is being dozed after the user fixed it.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final channel = TunnelChannel.instance;
    final flags = await Future.wait([
      channel.autoStart().catchError((Object _) => _autoStart),
      channel.batteryOptimized().catchError((Object _) => _batteryOptimized),
      channel.memoryLimit().catchError((Object _) => _memoryLimit),
      channel.debugMode().catchError((Object _) => _debugMode),
      channel.metered().catchError((Object _) => _metered),
      channel.wakeLock().catchError((Object _) => _wakeLock),
      channel.trafficStats().catchError((Object _) => _trafficStats),
      channel.resetOnNetworkChange().catchError((Object _) => _resetOnNetworkChange),
      channel.resetOnWake().catchError((Object _) => _resetOnWake),
      channel.groupInNotification().catchError((Object _) => _groupInNotification),
    ]);
    final alwaysOn = await channel.alwaysOn().catchError((Object _) => _alwaysOn);
    final speed = await channel.notificationSpeed().catchError((Object _) => _notificationSpeed);
    final interval = await channel.notificationInterval().catchError(
      (Object _) => _notificationInterval,
    );
    if (!mounted) return;
    setState(() {
      _autoStart = flags[0];
      _batteryOptimized = flags[1];
      _memoryLimit = flags[2];
      _debugMode = flags[3];
      _metered = flags[4];
      _wakeLock = flags[5];
      _trafficStats = flags[6];
      _resetOnNetworkChange = flags[7];
      _resetOnWake = flags[8];
      _groupInNotification = flags[9];
      _alwaysOn = alwaysOn;
      _notificationSpeed = speed;
      _notificationInterval = interval;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = TunnelScope.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = controller.settings;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsGeneral)),
      body: ListView(
        padding: EdgeInsets.only(bottom: bottomInset(context, extra: 24)),
        children: [
          SettingsTile(
            icon: Icons.translate,
            title: l10n.language,
            subtitle: languageLabel(l10n, controller.locale?.languageCode),
            onTap: () => pickLanguage(context, controller.locale?.languageCode),
          ),
          SettingsTile(
            icon: Icons.contrast,
            title: l10n.themeMode,
            subtitle: _themeLabel(l10n, controller.themeMode),
            onTap: () async {
              final choice = await pickOption<ThemeMode>(
                context,
                title: l10n.themeMode,
                options: ThemeMode.values,
                current: controller.themeMode,
                label: (value) => _themeLabel(l10n, value),
              );
              if (choice != null) await controller.setThemeMode(choice);
            },
          ),
          SwitchListTile(
            value: controller.autoCheckIp,
            secondary: const Icon(Icons.public),
            title: Text(l10n.autoCheckIp),
            subtitle: Text(l10n.autoCheckIpBody),
            onChanged: controller.setAutoCheckIp,
          ),
          SettingsTile(
            icon: Icons.speed,
            title: l10n.notificationSpeed,
            subtitle: _speedLabel(l10n, _notificationSpeed),
            onTap: () async {
              final choice = await pickOption<String>(
                context,
                title: l10n.notificationSpeed,
                options: NotificationSpeed.values,
                current: _notificationSpeed,
                label: (value) => _speedLabel(l10n, value),
                // The split costs more than the other two, and the reader deserves
                // to know that before choosing it rather than after.
                describe: (value) =>
                    value == NotificationSpeed.split ? l10n.notificationSpeedSplitBody : '',
              );
              if (choice == null) return;
              setState(() => _notificationSpeed = choice);
              TunnelChannel.instance.setNotificationSpeed(choice).catchError((Object _) {});
            },
          ),
          SettingsTile(
            icon: Icons.timer_outlined,
            title: l10n.notificationInterval,
            subtitle: l10n.secondsValue(_notificationInterval),
            description: l10n.notificationIntervalBody,
            onTap: () async {
              final choice = await pickOption<int>(
                context,
                title: l10n.notificationInterval,
                options: const [1, 2, 3, 5, 10],
                current: _notificationInterval,
                label: l10n.secondsValue,
              );
              if (choice == null) return;
              setState(() => _notificationInterval = choice);
              TunnelChannel.instance.setNotificationInterval(choice).catchError((Object _) {});
            },
          ),
          SwitchListTile(
            value: _groupInNotification,
            secondary: const Icon(Icons.label_outline),
            title: Text(l10n.groupInNotification),
            subtitle: Text(l10n.groupInNotificationBody),
            onChanged: (value) {
              setState(() => _groupInNotification = value);
              TunnelChannel.instance.setGroupInNotification(value).catchError((Object _) {});
            },
          ),
          SwitchListTile(
            value: controller.hapticFeedback,
            secondary: const Icon(Icons.vibration),
            title: Text(l10n.hapticFeedback),
            subtitle: Text(l10n.hapticFeedbackBody),
            onChanged: controller.setHapticFeedback,
          ),
          SwitchListTile(
            value: _autoStart,
            secondary: const Icon(Icons.restart_alt),
            title: Text(l10n.connectAfterRestart),
            subtitle: Text(l10n.connectAfterRestartBody),
            onChanged: (value) {
              setState(() => _autoStart = value);
              TunnelChannel.instance.setAutoStart(value).catchError((Object _) {});
            },
          ),
          ListTile(
            leading: Icon(
              _alwaysOn.lockdown ? Icons.lock : Icons.lock_open,
              // Only the unprotected state is called out in colour. Always-on
              // without the lockdown still leaks on every drop, which is the case
              // worth noticing.
              color: _alwaysOn.known && !_alwaysOn.lockdown
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            isThreeLine: true,
            title: Text(l10n.alwaysOn),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_alwaysOnSummary(l10n)),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    l10n.alwaysOnHowTo,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final opened = await TunnelChannel.instance.openVpnSettings().catchError(
                (Object _) => false,
              );
              if (!opened) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(l10n.openVpnSettings),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
          ListTile(
            leading: Icon(
              _batteryOptimized ? Icons.battery_alert : Icons.battery_charging_full,
              color: _batteryOptimized ? Theme.of(context).colorScheme.error : null,
            ),
            title: Text(l10n.batteryOptimization),
            subtitle: Text(
              _batteryOptimized ? l10n.batteryOptimizationOn : l10n.batteryOptimizationOff,
            ),
            // Nothing to ask for once it is already exempt.
            trailing: _batteryOptimized ? const Icon(Icons.open_in_new, size: 18) : null,
            onTap: _batteryOptimized
                ? () => TunnelChannel.instance.requestIgnoreBatteryOptimizations().catchError(
                    (Object _) => false,
                  )
                : null,
          ),
          const Divider(height: 32),
          SwitchListTile(
            value: _metered,
            secondary: const Icon(Icons.money_off),
            title: Text(l10n.metered),
            subtitle: Text(l10n.meteredBody),
            onChanged: (value) {
              setState(() => _metered = value);
              TunnelChannel.instance.setMetered(value).catchError((Object _) {});
            },
          ),
          SwitchListTile(
            value: _wakeLock,
            secondary: const Icon(Icons.bolt),
            title: Text(l10n.wakeLock),
            subtitle: Text(l10n.wakeLockBody),
            onChanged: (value) {
              setState(() => _wakeLock = value);
              TunnelChannel.instance.setWakeLock(value).catchError((Object _) {});
            },
          ),
          SwitchListTile(
            value: _trafficStats,
            secondary: const Icon(Icons.insights),
            title: Text(l10n.trafficStats),
            subtitle: Text(l10n.trafficStatsBody),
            onChanged: (value) {
              setState(() => _trafficStats = value);
              TunnelChannel.instance.setTrafficStats(value).catchError((Object _) {});
            },
          ),
          SwitchListTile(
            value: _resetOnNetworkChange,
            secondary: const Icon(Icons.wifi_protected_setup),
            title: Text(l10n.resetOnNetworkChange),
            subtitle: Text(l10n.resetOnNetworkChangeBody),
            onChanged: (value) {
              setState(() => _resetOnNetworkChange = value);
              TunnelChannel.instance.setResetOnNetworkChange(value).catchError((Object _) {});
            },
          ),
          SwitchListTile(
            value: _resetOnWake,
            secondary: const Icon(Icons.brightness_high_outlined),
            title: Text(l10n.resetOnWake),
            subtitle: Text(l10n.resetOnWakeBody),
            onChanged: (value) {
              setState(() => _resetOnWake = value);
              TunnelChannel.instance.setResetOnWake(value).catchError((Object _) {});
            },
          ),
          SwitchListTile(
            value: _memoryLimit,
            secondary: const Icon(Icons.memory),
            title: Text(l10n.memoryLimit),
            subtitle: Text(l10n.memoryLimitBody),
            onChanged: (value) {
              setState(() => _memoryLimit = value);
              TunnelChannel.instance.setMemoryLimit(value).catchError((Object _) {});
            },
          ),
          SwitchListTile(
            value: controller.crashReports,
            secondary: const Icon(Icons.bug_report_outlined),
            title: Text(l10n.crashReports),
            subtitle: Text(l10n.crashReportsBody),
            onChanged: controller.setCrashReports,
          ),
          if (controller.crashReports)
            SettingsTile(
              icon: Icons.description_outlined,
              title: l10n.crashReportsView,
              subtitle: l10n.crashReportsBody,
              onTap: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const CrashLogScreen())),
            ),
          SwitchListTile(
            value: _debugMode,
            secondary: const Icon(Icons.developer_mode),
            title: Text(l10n.debugMode),
            subtitle: Text(l10n.debugModeBody),
            onChanged: (value) {
              setState(() => _debugMode = value);
              TunnelChannel.instance.setDebugMode(value).catchError((Object _) {});
            },
          ),
          SettingsTile(
            icon: Icons.article_outlined,
            title: l10n.logLevel,
            subtitle: settings.logLevel,
            description: l10n.logLevelBody,
            onTap: () async {
              final choice = await pickOption<String>(
                context,
                title: l10n.logLevel,
                options: ConfigBuilder.logLevels,
                current: settings.logLevel,
                label: (value) => value,
              );
              if (choice == null || !context.mounted) return;
              await TunnelScope.read(context).updateSettings(settings.copyWith(logLevel: choice));
            },
          ),
          SettingsTile(
            icon: Icons.link,
            title: l10n.testUrl,
            subtitle: settings.testUrl,
            onTap: () async {
              final value = await promptText(
                context,
                title: l10n.testUrl,
                initial: settings.testUrl,
                helper: l10n.testUrlBody,
                hint: ConfigBuilder.defaultTestUrl,
                validate: (value) {
                  final uri = Uri.tryParse(value);
                  return uri != null && uri.hasScheme && uri.host.isNotEmpty
                      ? null
                      : l10n.invalidValue;
                },
              );
              if (value == null || !context.mounted) return;
              await TunnelScope.read(context).updateSettings(settings.copyWith(testUrl: value));
            },
          ),
          SettingsTile(
            icon: Icons.timer_outlined,
            title: l10n.testInterval,
            subtitle: l10n.minutesValue(settings.testIntervalMinutes),
            description: l10n.testIntervalBody,
            onTap: () async {
              final choice = await pickOption<int>(
                context,
                title: l10n.testInterval,
                options: const [1, 3, 5, 10, 30, 60],
                current: settings.testIntervalMinutes,
                label: l10n.minutesValue,
              );
              if (choice == null || !context.mounted) return;
              await TunnelScope.read(context)
                  .updateSettings(settings.copyWith(testIntervalMinutes: choice));
            },
          ),
        ],
      ),
    );
  }

  static String _speedLabel(AppLocalizations l10n, String mode) => switch (mode) {
    NotificationSpeed.off => l10n.notificationSpeedOff,
    NotificationSpeed.split => l10n.notificationSpeedSplit,
    _ => l10n.notificationSpeedTotal,
  };

  /// Android answers this only through a running VpnService on API 29+, and the
  /// answer describes the instance that asked. So a positive reading is worth
  /// trusting and a negative one is not: it means "not seen", which is a weaker
  /// claim than "off" and is worded as one. Getting this wrong in the confident
  /// direction would tell someone their kill switch is off when it is on.
  String _alwaysOnSummary(AppLocalizations l10n) {
    if (!_alwaysOn.known) return l10n.alwaysOnUnknown;
    if (_alwaysOn.lockdown) return l10n.alwaysOnLockdown;
    if (_alwaysOn.active) return l10n.alwaysOnActive;
    return l10n.alwaysOnInactive;
  }

  static String _themeLabel(AppLocalizations l10n, ThemeMode mode) => switch (mode) {
    ThemeMode.system => l10n.themeSystem,
    ThemeMode.light => l10n.themeLight,
    ThemeMode.dark => l10n.themeDark,
  };
}
