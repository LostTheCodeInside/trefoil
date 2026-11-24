import 'dart:async';

import 'package:flutter/services.dart';

import 'profile/config_builder.dart';
import 'profile/loopback_auth.dart';
import 'tunnel_status.dart';

/// Thrown when the native side rejects a request. Carries the sing-box error text,
/// which for a bad config is usually the most useful thing we can show the user.
class TunnelException implements Exception {
  const TunnelException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Dart's view of the native tunnel.
///
/// This is the only place in the app that knows a platform channel exists. Everything
/// above it deals in [TunnelStatus] and [CoreLogEntry], so swapping the state
/// management layer — or eventually adding an iOS implementation behind the same
/// channel names — touches nothing else.
class TunnelChannel {
  /// Public so tests can subclass and override the streams. The app itself should
  /// always go through [instance] -- a second one would open a second native
  /// subscription for the same events.
  TunnelChannel();

  static final TunnelChannel instance = TunnelChannel();

  static const _control = MethodChannel('trefoil/control');
  static const _statusEvents = EventChannel('trefoil/status');
  static const _logEvents = EventChannel('trefoil/logs');
  static const _groupEvents = EventChannel('trefoil/groups');
  static const _connectionEvents = EventChannel('trefoil/connections');
  static const _trafficEvents = EventChannel('trefoil/traffic');

  Stream<TunnelStatus>? _status;
  Stream<List<CoreLogEntry>>? _logs;
  Stream<List<OutboundGroup>>? _groups;

  /// Broadcast so several widgets can watch the tunnel without each opening its own
  /// native subscription; the native side only publishes one stream.
  Stream<TunnelStatus> get status => _status ??= _statusEvents
      .receiveBroadcastStream()
      .map((event) => TunnelStatus.fromMap((event as Map).cast<Object?, Object?>()))
      .asBroadcastStream();

  /// Batched: the core can emit hundreds of lines a second while a tunnel comes up,
  /// and delivering them one event per line would swamp the platform channel.
  Stream<List<CoreLogEntry>> get logs => _logs ??= _logEvents
      .receiveBroadcastStream()
      .map(
        (event) => (event as List)
            .map((e) => CoreLogEntry.fromMap((e as Map).cast<Object?, Object?>()))
            .toList(growable: false),
      )
      .asBroadcastStream();

  /// Outbound groups with their latency measurements, republished whenever the core
  /// finishes a test or the selection changes.
  Stream<List<OutboundGroup>> get groups => _groups ??= _groupEvents
      .receiveBroadcastStream()
      .map(
        (event) => (event as List)
            .map((e) => OutboundGroup.fromMap((e as Map).cast<Object?, Object?>()))
            .toList(growable: false),
      )
      .asBroadcastStream();

  /// Open connections, updated as they come and go.
  ///
  /// Not broadcast and not cached: the native subscription starts when this stream
  /// is listened to and stops when it is cancelled, so the core is not reporting
  /// every byte to a screen nobody has open.
  Stream<List<ActiveConnection>> get connections => _connectionEvents.receiveBroadcastStream().map(
    (event) => (event as List)
        .map((e) => ActiveConnection.fromMap((e as Map).cast<Object?, Object?>()))
        .toList(growable: false),
  );

  /// Throughput split between the proxy and direct, once a second.
  ///
  /// Like [connections] this is neither cached nor broadcast: the native side only
  /// subscribes to the core's per-connection feed while something is listening here,
  /// and that feed is the chattiest thing the core publishes.
  Stream<TrafficSplit> get trafficSplit => _trafficEvents.receiveBroadcastStream().map(
    (event) => TrafficSplit.fromMap((event as Map).cast<Object?, Object?>()),
  );

  Future<void> closeConnections() => _invoke<void>('closeConnections');

  Future<void> closeConnection(String id) => _invoke<void>('closeConnection', id);

  /// Switches the quick routing mode without reconnecting.
  Future<void> setMode(String mode) => _invoke<void>('setMode', mode);

  /// Measures every member of a group; results arrive on [groups].
  Future<void> urlTest([String group = 'proxy']) => _invoke<void>('urlTest', group);

  /// Switches the active server without restarting the tunnel.
  Future<void> selectOutbound({required String group, required String outbound}) =>
      _invoke<void>('selectOutbound', {'group': group, 'outbound': outbound});

  /// Shows the system VPN consent dialog if it has not been granted yet.
  /// Returns false when the user declines — not an error, just a refusal.
  Future<bool> prepare() => _invoke<bool>('prepareVpn').then((value) => value ?? false);

  /// [xrayConfig] is only supplied for servers the sing-box core cannot run; the
  /// native side treats its absence as "sing-box alone".
  ///
  /// [amneziaSocks] is where the AmneziaWG core serves SOCKS and the credentials it
  /// demands — the same set [config] dials it with. Xray's travel inside
  /// [xrayConfig]; this core takes a WireGuard file, which has no place for them.
  ///
  /// [proxyLabel] and [directLabel] are the translations the notification uses for
  /// the traffic split. They travel with the start request because the service
  /// outlives the UI and, after a reboot, starts with no Flutter engine at all.
  Future<void> start({
    required String config,
    required String profileName,
    String? xrayConfig,
    String? amneziaConfig,
    LoopbackAuth? amneziaSocks,
    String proxyLabel = 'Proxy',
    String directLabel = 'Direct',
    String groupName = '',
  }) => _invoke<void>('start', {
    'config': config,
    'configVersion': ConfigBuilder.generatedConfigVersion,
    'profileName': profileName,
    'xrayConfig': ?xrayConfig,
    'amneziaConfig': ?amneziaConfig,
    if (amneziaConfig != null && amneziaSocks != null) ...{
      'amneziaPort': amneziaSocks.amneziaPort,
      'amneziaUsername': amneziaSocks.username,
      'amneziaPassword': amneziaSocks.password,
    },
    'proxyLabel': proxyLabel,
    'directLabel': directLabel,
    'groupName': groupName,
  });

  Future<void> stop() => _invoke<void>('stop');

  /// [ConfigBuilder.generatedConfigVersion] of the config the native side holds, or
  /// 0 for one written before versions were recorded.
  Future<int> configVersion() async => await _invoke<int>('configVersion') ?? 0;

  /// Copies [text] flagged as sensitive, so Android leaves it out of its clipboard
  /// preview and keyboards keep it out of their history.
  Future<void> copySensitive(String text) => _invoke<void>('copySensitive', text);

  /// Writes [text] to a file the user picks with the system picker. False when they
  /// back out.
  Future<bool> saveTextFile({required String name, required String text}) =>
      _invoke<bool>('saveTextFile', {'name': name, 'text': text}).then((v) => v ?? false);

  /// The text of a file the user picks with the system picker; null when they back
  /// out.
  Future<String?> openTextFile() => _invoke<String>('openTextFile');

  /// The language the notification, tile and widget should use; null follows the
  /// device. They are drawn natively, often with no Flutter engine to ask.
  Future<void> setAppLocale(String? code) => _invoke<void>('setAppLocale', code);

  /// Drops a removed server's recorded traffic. The service owns that file.
  Future<void> forgetServerUsage(String tag) => _invoke<void>('forgetServerUsage', tag);

  Future<TunnelStatus> currentStatus() async {
    final result = await _invoke<Map<Object?, Object?>>('currentStatus');
    return result == null ? TunnelStatus.disconnected : TunnelStatus.fromMap(result);
  }

  /// Returns null when the config is valid, or the parser's complaint when it is not.
  Future<String?> validateConfig(String config) => _invoke<String>('validateConfig', config);

  /// Canonical sing-box formatting — also the cheapest way to pretty-print a config.
  Future<String> formatConfig(String config) async =>
      await _invoke<String>('formatConfig', config) ?? config;

  /// A fresh WireGuard key pair as "privateKey\npublicKey", both base64.
  Future<String> generateWireGuardKey() async =>
      await _invoke<String>('generateWireGuardKey') ?? '';

  /// Encrypts a backup with a password. Returns base64 text.
  Future<String> encryptBackup({required String data, required String password}) async =>
      await _invoke<String>('encryptBackup', {'data': data, 'password': password}) ?? '';

  Future<String> decryptBackup({required String data, required String password}) async =>
      await _invoke<String>('decryptBackup', {'data': data, 'password': password}) ?? '';

  /// What the ongoing notification shows: one of [NotificationSpeed].
  Future<String> notificationSpeed() async =>
      await _invoke<String>('notificationSpeed') ?? NotificationSpeed.total;

  Future<void> setNotificationSpeed(String mode) => _invoke<void>('setNotificationSpeed', mode);

  /// Seconds between notification updates. Fewer updates, less battery.
  Future<int> notificationInterval() async => await _invoke<int>('notificationInterval') ?? 1;

  Future<void> setNotificationInterval(int seconds) =>
      _invoke<void>('setNotificationInterval', seconds);

  /// Close open connections when the underlying network changes. They do not
  /// survive a handover; they simply stop carrying data until something times out.
  Future<bool> resetOnNetworkChange() async => await _invoke<bool>('resetOnNetworkChange') ?? false;

  Future<void> setResetOnNetworkChange(bool enabled) =>
      _invoke<void>('setResetOnNetworkChange', enabled);

  /// The same, when the device wakes.
  Future<bool> resetOnWake() async => await _invoke<bool>('resetOnWake') ?? false;

  Future<void> setResetOnWake(bool enabled) => _invoke<void>('setResetOnWake', enabled);

  /// Whether the notification names the subscription a server came from.
  Future<bool> groupInNotification() async => await _invoke<bool>('groupInNotification') ?? false;

  Future<void> setGroupInNotification(bool enabled) =>
      _invoke<void>('setGroupInNotification', enabled);

  /// Report the tunnel to Android as metered, so background sync backs off.
  Future<bool> metered() async => await _invoke<bool>('metered') ?? false;

  Future<void> setMetered(bool enabled) => _invoke<void>('setMetered', enabled);

  /// Keep the CPU awake for as long as the tunnel is up. Costs battery by design.
  Future<bool> wakeLock() async => await _invoke<bool>('wakeLock') ?? false;

  Future<void> setWakeLock(bool enabled) => _invoke<void>('setWakeLock', enabled);

  /// Whether daily usage totals are recorded at all.
  Future<bool> trafficStats() async => await _invoke<bool>('trafficStats') ?? true;

  Future<void> setTrafficStats(bool enabled) => _invoke<void>('setTrafficStats', enabled);

  /// Trades throughput for a smaller heap. Applied to the running core at once.
  Future<bool> memoryLimit() async => await _invoke<bool>('memoryLimit') ?? false;

  Future<void> setMemoryLimit(bool enabled) => _invoke<void>('setMemoryLimit', enabled);

  /// libbox's own debug instrumentation. Read once per process, so a change only
  /// lands after the app is restarted.
  Future<bool> debugMode() async => await _invoke<bool>('debugMode') ?? false;

  Future<void> setDebugMode(bool enabled) => _invoke<void>('setDebugMode', enabled);

  /// True while Android may still doze this app — which for an always-on VPN shows
  /// up as the tunnel dropping with the screen off.
  Future<bool> batteryOptimized() async => await _invoke<bool>('batteryOptimized') ?? false;

  /// Opens the system exemption prompt. False when no screen could be opened at all.
  Future<bool> requestIgnoreBatteryOptimizations() async =>
      await _invoke<bool>('requestIgnoreBatteryOptimizations') ?? false;

  /// Whether the tunnel reconnects after a reboot.
  /// What Android last reported about always-on VPN. See [AlwaysOnStatus].
  Future<AlwaysOnStatus> alwaysOn() async {
    final map = await _invoke<Map<Object?, Object?>>('alwaysOn');
    return AlwaysOnStatus.fromMap(map ?? const {});
  }

  /// Opens Android's VPN settings. False when even the fallback would not open.
  Future<bool> openVpnSettings() async => await _invoke<bool>('openVpnSettings') ?? false;

  Future<bool> autoStart() async => await _invoke<bool>('autoStart') ?? false;

  Future<void> setAutoStart(bool enabled) => _invoke<void>('setAutoStart', enabled);

  Future<List<InstalledApp>> installedApps() async {
    final result = await _invoke<List<Object?>>('installedApps');
    return (result ?? const [])
        .map((e) => InstalledApp.fromMap((e as Map).cast<Object?, Object?>()))
        .toList(growable: false);
  }

  /// One app's launcher icon as PNG bytes, or null when Android has none to give.
  ///
  /// Asked for one app at a time: shipping every icon with [installedApps] would put
  /// megabytes through the channel to draw a dozen rows.
  Future<Uint8List?> appIcon(String packageName) => _invoke<Uint8List>('appIcon', packageName);

  /// Versions of both bundled cores, keyed `singBox` and `xray`.
  Future<Map<String, String>> coreVersions() async {
    final result = await _invoke<Map<Object?, Object?>>('coreVersion');
    return {
      for (final entry in (result ?? const {}).entries)
        entry.key.toString(): entry.value.toString(),
    };
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _control.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw TunnelException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw const TunnelException(
        'unsupported',
        'The tunnel is only available on Android in this build.',
      );
    }
  }
}

/// What the ongoing notification reports. Mirrors AppPrefs on the Android side.
abstract final class NotificationSpeed {
  static const off = 'off';
  static const total = 'total';

  /// Proxy and direct separately. Costs more than the others: the aggregate counters
  /// carry no breakdown by outbound, so this keeps the core's per-connection feed
  /// running for as long as the tunnel is up, with the app closed as well.
  static const split = 'split';

  static const values = [off, total, split];
}

/// Whether Android is running this app as an always-on VPN, and whether it blocks
/// traffic while the tunnel is down.
///
/// [known] is the field that matters: only a running VpnService can ask, and only
/// on API 29+, so before the first connection there is no answer. Reporting "not
/// known" as "off" would tell someone their kill switch is off when it may be on —
/// which is the one direction this must never be wrong in.
class AlwaysOnStatus {
  const AlwaysOnStatus({this.known = false, this.active = false, this.lockdown = false});

  final bool known;
  final bool active;
  final bool lockdown;

  factory AlwaysOnStatus.fromMap(Map<Object?, Object?> map) => AlwaysOnStatus(
    known: map['known'] as bool? ?? false,
    active: map['active'] as bool? ?? false,
    lockdown: map['lockdown'] as bool? ?? false,
  );
}
