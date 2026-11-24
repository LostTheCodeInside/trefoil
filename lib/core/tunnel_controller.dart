import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
// Narrowed deliberately: this layer holds app state, not UI, and ThemeMode is
// the only thing it needs from Material.
import 'package:flutter/material.dart' show ThemeMode;

import 'action_error.dart';
import 'crash_log.dart';
import 'exit_ip.dart';
import 'profile/config_builder.dart';
import 'profile/loopback_auth.dart';
import 'profile/outbound.dart';
import 'profile/profile_store.dart';
import 'profile/routing.dart';
import 'profile/rule_set_store.dart';
import 'profile/server_usage.dart';
import 'reachability.dart';
import 'speed_test.dart';
import 'profile/warp.dart';
import 'profile/wireguard_config.dart';
import 'profile/share_link.dart';
import 'profile/xray_config.dart';
import 'tunnel_channel.dart';
import 'tunnel_status.dart';

/// Application state: servers, settings, and the live tunnel.
///
/// A [ChangeNotifier] rather than a state-management package. The app has one screen
/// worth of shared state and it all flows from two native streams, so a package would
/// add a dependency without removing any work. Swapping this for Riverpod or GetX
/// later is mechanical: the streams and the store below stay exactly as they are.
///
/// Not everything here goes through [notifyListeners], and that distinction matters
/// more than it looks. Three of the native streams publish once a second for as long
/// as the tunnel is up — traffic counters, log lines, latency measurements. Routing
/// those through the one notifier every widget listens to meant a byte counter
/// ticking over rebuilt the entire tree, `MaterialApp` included, once a second
/// forever. So they are published on their own [Listenable]s ([telemetry],
/// [logsChanged], [groupsChanged]) and only the widget that draws each one listens.
/// [notifyListeners] is reserved for things that genuinely change the app's state:
/// the tunnel's stage, the server list, settings.
class TunnelController extends ChangeNotifier {
  TunnelController({TunnelChannel? channel, ProfileStore? store})
    : _channel = channel ?? TunnelChannel.instance,
      _store = store ?? ProfileStore.instance;

  final TunnelChannel _channel;
  final ProfileStore _store;

  /// For the few things that subscribe on their own schedule rather than through
  /// this controller — the split speed meter, which only wants the core's
  /// per-connection feed running while it is on screen.
  TunnelChannel get channel => _channel;

  StreamSubscription<TunnelStatus>? _statusSub;
  StreamSubscription<List<CoreLogEntry>>? _logSub;
  StreamSubscription<List<OutboundGroup>>? _groupSub;

  ProfileData _data = const ProfileData();
  TunnelStatus _status = TunnelStatus.disconnected;
  bool _loading = true;
  ActionError? _lastActionError;

  /// Live traffic counters, republished every second while connected.
  ///
  /// Separate from [notifyListeners] on purpose: this is the fastest-moving thing in
  /// the app and only one small panel draws it.
  final ValueNotifier<TunnelStatus> telemetry = ValueNotifier(TunnelStatus.disconnected);

  /// Pinged when [logs] changes. Only the log view listens.
  final Listenable logsChanged = _Signal();

  /// The exit address, once looked up. Null while unknown or while disconnected.
  ///
  /// On its own notifier: the lookup lands seconds after connecting and only one
  /// line renders it.
  final ValueNotifier<ExitIp?> exitIp = ValueNotifier(null);

  /// Pinged when the outbound groups change — latency results, the live selection,
  /// and whether a measurement is in flight. Only the server list listens.
  final Listenable groupsChanged = _Signal();

  /// Capped so a long-running tunnel cannot grow the log view without bound.
  static const _maxLogLines = 500;
  final Queue<CoreLogEntry> _logs = Queue<CoreLogEntry>();

  ConfigBuilder _settings = ConfigBuilder(routing: RoutingSettings.defaults);

  // ---- exposed state ----------------------------------------------------

  bool get isLoading => _loading;

  /// Guards the late arrival of anything asynchronous: notifying after dispose
  /// throws, and reading a file is slower than a screen can be closed.
  bool _disposed = false;

  /// What the native side last reported, or "starting" from the moment the user asked:
  /// fetching rule sets and the permission dialog come before the tunnel does, and a
  /// button that still reads "Connect" through them is a button that looks dead.
  TunnelStatus get status => isPreparing ? _preparingStatus : _status;

  static const _preparingStatus = TunnelStatus(stage: TunnelStage.starting);

  /// Connecting, with the tunnel itself not started yet. Still the app's to call off.
  bool get isPreparing => _connecting && _status.stage == TunnelStage.stopped;

  bool _connecting = false;

  /// Goes up with every start and every stop, so one that was overtaken while it waited
  /// for something can tell, and leave the rest to the one that overtook it.
  int _attempt = 0;

  // Views, not copies. These are read during build, and `List.unmodifiable` copies
  // the whole list every time it is called -- which for a subscription with a few
  // hundred servers is real work repeated for nothing.
  /// The same view for as long as the list underneath is the same, so a screen can
  /// tell "nothing changed" by identity rather than by comparing every server. Every
  /// change to the list replaces it rather than editing it in place.
  List<Outbound> get servers {
    final source = _data.servers;
    if (!identical(source, _serversSource)) {
      _serversSource = source;
      _serversView = UnmodifiableListView(source);
    }
    return _serversView;
  }

  List<Outbound>? _serversSource;
  List<Outbound> _serversView = const [];

  List<Subscription> get subscriptions => UnmodifiableListView(_data.subscriptions);
  Outbound? get selected => _data.selected;
  ConfigBuilder get settings => _settings;

  /// Language override, or null to follow the device.
  ///
  /// Published on its own notifier because `MaterialApp` is what consumes it, and
  /// rebuilding `MaterialApp` is expensive enough that it must not happen for any
  /// other reason. A [ValueNotifier] also only fires on a real change, so setting
  /// the same locale twice costs nothing.
  final ValueNotifier<Locale?> localeListenable = ValueNotifier(null);

  Locale? get locale => localeListenable.value;

  /// Light, dark, or follow the device. On its own notifier for the same reason as
  /// the locale: it is a `MaterialApp` input and nothing else.
  final ValueNotifier<ThemeMode> themeModeListenable = ValueNotifier(ThemeMode.system);

  ThemeMode get themeMode => themeModeListenable.value;

  /// Translations the notification needs for the traffic split.
  ///
  /// Held here rather than looked up at the point of use because this layer has no
  /// BuildContext, and the service on the other side has no Flutter at all. The
  /// shell keeps them current; the defaults are what the notification said in every
  /// language before it could be told otherwise.
  String _proxyLabel = 'Proxy';
  String _directLabel = 'Direct';

  /// The subscription a server came from, or empty for a hand-added one.
  String _subscriptionNameOf(Outbound server) {
    final id = server.subscriptionId;
    if (id == null || id.isEmpty) return '';
    for (final subscription in _data.subscriptions) {
      if (subscription.id == id) return subscription.name;
    }
    return '';
  }

  void setNotificationLabels({required String proxy, required String direct}) {
    _proxyLabel = proxy;
    _directLabel = direct;
  }

  bool get hapticFeedback => _data.hapticFeedback;
  bool get autoCheckIp => _data.autoCheckIp;
  bool get crashReports => _data.crashReports;
  bool get insecureDownloads => _data.insecureDownloads;

  Future<void> setHapticFeedback(bool value) async {
    _data = _data.copyWith(hapticFeedback: value);
    await _persist();
  }

  Future<void> setAutoCheckIp(bool value) async {
    _data = _data.copyWith(autoCheckIp: value);
    await _persist();
    if (value) {
      unawaited(refreshExitIp());
    } else {
      _forgetExitIp();
    }
  }

  Future<void> setInsecureDownloads(bool value) async {
    _data = _data.copyWith(insecureDownloads: value);
    await _persist();
  }

  Future<void> setCrashReports(bool value) async {
    _data = _data.copyWith(crashReports: value);
    _applyCrashReports();
    await _persist();
  }

  void _applyCrashReports() {
    if (_data.crashReports) {
      CrashLog.instance.install();
    } else {
      CrashLog.instance.uninstall();
    }
  }

  /// Only the latest lookup may answer, and only while what it asked about is still so.
  int _exitIpLookup = 0;

  /// Looks up the exit address. Safe to call when disconnected; it simply reports
  /// whatever route the app currently has.
  ///
  /// The answer takes seconds, which is long enough to disconnect or to change server.
  /// One that comes back after that is an address nothing leaves through any more.
  Future<void> refreshExitIp() async {
    final lookup = ++_exitIpLookup;
    final found = await const ExitIpProbe().lookup();
    if (_disposed || lookup != _exitIpLookup) return;
    exitIp.value = found;
  }

  /// Forgets the exit address: the way out has changed, or there is none.
  void _forgetExitIp() {
    _exitIpLookup++;
    exitIp.value = null;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _data = _data.copyWith(themeModeName: mode.name);
    themeModeListenable.value = mode;
    await _persist();
  }

  static ThemeMode _themeModeOf(String name) =>
      ThemeMode.values.firstWhere((e) => e.name == name, orElse: () => ThemeMode.system);

  /// Hands the language to the notification, tile and widget. Best effort: a native
  /// side that cannot take it keeps the device language, which is still readable.
  void _tellNativeLocale() {
    unawaited(
      _channel.setAppLocale(localeListenable.value?.languageCode).catchError((Object _) {}),
    );
  }

  /// Passing null goes back to following the device language.
  Future<void> setLocale(String? code) async {
    _data = _data.copyWith(localeCode: code, clearLocale: code == null);
    localeListenable.value = code == null ? null : Locale(code);
    await _persist();
  }

  /// The settings the running tunnel was actually built from.
  ///
  /// Kept so the UI can tell the user when what they are looking at no longer
  /// matches what is running — most settings live in the generated config and only
  /// take effect on the next connect.
  ///
  /// Held encoded: comparing settings means comparing every nested field, and the
  /// encoder already knows how to walk them.
  String? _appliedSettingsEncoded;

  /// [_settings] encoded, recomputed only when the settings themselves change.
  ///
  /// This used to be encoded twice on every read, and the read happens in the shell's
  /// build method -- so every rebuild serialised the whole settings tree to JSON
  /// twice to answer a question whose answer almost never changes.
  late String _settingsEncoded = jsonEncode(_settings.toJson());

  /// True when a config-affecting setting changed while connected.
  ///
  /// Mode and server switches are excluded by construction: those are applied
  /// live by the core and never touch the config.
  bool get needsReconnect {
    final applied = _appliedSettingsEncoded;
    if (!_status.stage.isActive || applied == null) return false;
    return applied != _settingsEncoded;
  }

  /// The quick routing mode the core reports, or null while disconnected.
  String? get mode => _status.mode.isEmpty ? null : _status.mode;

  /// Switches quick mode. Instant: every mode's rules are already in the config.
  Future<void> setMode(String value) async {
    try {
      await _channel.setMode(value);
    } on TunnelException catch (e) {
      _fail(e);
    }
  }

  /// Materialised once per incoming batch rather than once per build: the buffer
  /// holds up to [_maxLogLines] entries and the log view rebuilds far more often
  /// than the core produces lines.
  List<CoreLogEntry>? _logsView;
  List<CoreLogEntry> get logs => _logsView ??= List.unmodifiable(_logs);

  List<OutboundGroup> _groups = const [];

  /// The selector holding the servers, or null while the tunnel is down.
  OutboundGroup? get proxyGroup {
    for (final group in _groups) {
      if (group.tag == ConfigBuilder.proxyTag) return group;
    }
    return null;
  }

  /// Latency per server tag, from the last measurement. Empty while disconnected.
  ///
  /// Cached because the server list reads it while building each row: rebuilding the
  /// map per row made drawing the list quadratic in the number of servers.
  Map<String, OutboundItem>? _latencyView;
  Map<String, OutboundItem> get latency => _latencyView ??= {
    for (final item in proxyGroup?.items ?? const <OutboundItem>[]) item.tag: item,
  };

  /// Which server is actually carrying traffic right now. Differs from [selected]
  /// after a live switch, which deliberately does not rewrite the saved profile.
  String? get activeTag => proxyGroup?.selected;

  bool _testing = false;
  bool get isTesting => _testing;

  /// A failure from the last user action (connect, import…), cleared once shown.
  /// The last thing the user asked for that failed, for the shell to say once.
  ActionError? get lastActionError => _lastActionError;

  /// See [ProfileData.needsReimport].
  bool get needsReimport => _data.needsReimport;

  /// Whether the tunnel is carrying anything, not merely whether it is up.
  ///
  /// Read from the latency measurement of whichever server is actually active. That
  /// measurement is the same question a user is asking — "does the other end answer
  /// through this tunnel?" — and the core already takes it, so nothing new goes over
  /// the wire to produce this.
  ///
  /// [TunnelHealth.unknown] in Direct mode on purpose: nothing goes through the proxy
  /// there, so its reachability says nothing about whether the phone has working
  /// internet, and warning about it would be noise.
  TunnelHealth get health {
    if (!_status.stage.isActive) return TunnelHealth.unknown;
    // Case-insensitively: this string is whatever the core reports, and hinging a
    // safety warning on the capitalisation of someone else's field is a silent
    // failure waiting to happen.
    if (_status.mode.toLowerCase() == ConfigBuilder.modeDirect.toLowerCase()) {
      return TunnelHealth.unknown;
    }
    final tag = activeTag ?? selected?.tag;
    final measured = tag == null ? null : latency[tag];
    if (measured == null || !measured.isMeasured) return TunnelHealth.unknown;
    return measured.isReachable ? TunnelHealth.healthy : TunnelHealth.stalled;
  }

  /// The most recent error the core logged, for explaining a stall.
  ///
  /// "Nothing is getting through" is the symptom; this is usually the cause, and it
  /// is already in memory. Without it the warning tells someone their tunnel is
  /// broken and leaves them nowhere to go.
  String? get lastCoreError {
    for (final entry in _logs.toList().reversed) {
      if (entry.isError) return entry.message;
    }
    return null;
  }

  /// Whether the connect button does anything: turn the tunnel off, call off a connect
  /// that has not started it yet, or connect to a server that can be used.
  ///
  /// A running tunnel can always be turned off. The server it runs on may since have
  /// been replaced in the list by one that cannot be used, or removed altogether.
  bool get canToggle {
    if (_status.stage.isActive || isPreparing) return true;
    return !_status.stage.isBusy && (selected?.isUsable ?? false);
  }

  /// Whether this app's own traffic goes through the tunnel.
  ///
  /// It does unless a per-app rule says otherwise, and that matters for anything the
  /// app measures for itself: a speed test run from outside the tunnel is a
  /// measurement of the plain connection wearing the tunnel's name.
  bool get appIsTunnelled {
    final perApp = _settings.perApp;
    if (perApp.packages.isEmpty) return true;
    // Fixed at build time; there is no API to ask for it that is worth a dependency.
    const self = 'com.lupangoding.trefoil';
    return switch (perApp.mode) {
      PerAppMode.include => perApp.packages.contains(self),
      PerAppMode.exclude => !perApp.packages.contains(self),
      PerAppMode.off => true,
    };
  }

  Map<String, ServerUsage> _serverUsage = const {};

  /// Lifetime traffic per server, as the service has recorded it.
  ///
  /// The session counters on the connect screen reset at every reconnect, which is
  /// often — most settings only take effect on one. These do not.
  Map<String, ServerUsage> get serverUsage => _serverUsage;

  /// Re-reads the totals from disk.
  ///
  /// The service writes them at most every thirty seconds and again when the tunnel
  /// stops, so this is called where a fresh number is worth having rather than on a
  /// timer: at startup, when the tunnel goes down, and when the list is opened.
  Future<void> refreshServerUsage() async {
    final usage = await ServerUsageStore.instance.load();
    if (_disposed) return;
    _serverUsage = usage;
    notifyListeners();
  }

  Future<void> init() async {
    _data = await _store.load();
    final stored = _data.settings ?? ConfigBuilder(routing: RoutingSettings.defaults);
    _settings = stored.withProxyCredentials();
    _settingsEncoded = jsonEncode(_settings.toJson());
    // Saved straight away when they were just minted, so the login an app was given
    // is still the login after the next launch.
    if (!identical(_settings, stored)) {
      _data = _data.copyWith(settings: _settings);
      unawaited(_persist());
    }
    final code = _data.localeCode;
    localeListenable.value = code == null ? null : Locale(code);
    // Every path that changes the language goes through the listenable, so this one
    // listener keeps the native side in step; the first call covers a choice made
    // before the native side could be told.
    localeListenable.addListener(_tellNativeLocale);
    _tellNativeLocale();
    themeModeListenable.value = _themeModeOf(_data.themeModeName);
    _applyCrashReports();
    _loading = false;
    if (_data.damaged) _fail(const ActionError(ActionErrorKind.profileDamaged));
    notifyListeners();

    // Seed from the native side first: the tunnel may already be running from a
    // previous launch, and the stream only reports changes from here on.
    try {
      _status = await _channel.currentStatus();
    } on TunnelException {
      // Non-Android host, or the channel is not up yet. The stream below will
      // correct this the moment anything actually happens.
    }
    unawaited(_flagStaleRunningConfig());

    unawaited(_autoRefreshSubscriptions());
    unawaited(refreshServerUsage());

    _statusSub = _channel.status.listen((value) {
      final previous = _status;
      _status = value;
      telemetry.value = value;
      if (!value.stage.isActive && _groups.isNotEmpty) {
        _groups = const [];
        _latencyView = null;
        _signal(groupsChanged);
      }
      if (value.stage != previous.stage) {
        _forgetExitIp();
        if (value.stage.isActive) {
          // Deliberately after the tunnel reports started rather than on the first
          // byte: the answer is only meaningful once traffic can actually flow.
          if (_data.autoCheckIp) unawaited(refreshExitIp());
        } else {
          // The core that was measuring is gone, and its answer with it.
          _testing = false;
          // The service flushes what it has when the tunnel stops, so this is the
          // moment the totals are complete.
          unawaited(refreshServerUsage());
        }
      }
      // Only a change the rest of the app can see is worth rebuilding for. The
      // counters move every second and are published on [telemetry] instead.
      if (value.stage != previous.stage ||
          value.error != previous.error ||
          value.mode != previous.mode ||
          value.profileName != previous.profileName) {
        notifyListeners();
      }
    }, onError: (Object _) {});
    _groupSub = _channel.groups.listen((value) {
      // The core republishes its groups every second while connected, changed or
      // not. A repeat is dropped here, before it rebuilds the server list: almost
      // every report is one. The selection is still checked, since that retry is
      // what the reports are for when a switch did not take.
      if (_testing || !listEquals(value, _groups)) {
        final before = health;
        final wasActive = activeTag;
        _groups = value;
        _testing = false;
        _latencyView = null;
        _signal(groupsChanged);
        // Another server is another way out, and a live switch changes nothing else
        // that would say so.
        if (wasActive != null && activeTag != wasActive) {
          _forgetExitIp();
          if (_data.autoCheckIp) unawaited(refreshExitIp());
        }
        // Group updates arrive on their own signal precisely so a latency reading
        // does not rebuild the tree. Health is the exception: it changes rarely, and
        // when it does the whole screen has something different to say.
        if (health != before) notifyListeners();
      }
      unawaited(_alignSelection());
    }, onError: (Object _) {});
    _logSub = _channel.logs.listen((batch) {
      if (batch.isEmpty) {
        _logs.clear();
      } else {
        _logs.addAll(batch);
        while (_logs.length > _maxLogLines) {
          _logs.removeFirst();
        }
      }
      _logsView = null;
      _signal(logsChanged);
    }, onError: (Object _) {});
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _statusSub?.cancel();
    _logSub?.cancel();
    _groupSub?.cancel();
    telemetry.dispose();
    localeListenable.dispose();
    themeModeListenable.dispose();
    exitIp.dispose();
    (logsChanged as _Signal).dispose();
    (groupsChanged as _Signal).dispose();
    super.dispose();
  }

  static void _signal(Listenable listenable) => (listenable as _Signal).ping();

  // ---- tunnel -----------------------------------------------------------

  /// Starts the tunnel on the selected server. Does nothing while a start is already
  /// under way: a second one beside it would draw its own loopback credentials and
  /// leave the two halves of the config disagreeing about them.
  Future<void> connect() async {
    if (_connecting) return;
    await _start(replace: false);
  }

  Future<void> _start({required bool replace}) async {
    final attempt = ++_attempt;
    _connecting = true;
    notifyListeners();
    try {
      await _prepareAndStart(attempt, replace: replace);
    } finally {
      // A later attempt, or a stop, has already had the last word on this.
      if (attempt == _attempt) {
        _connecting = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> _prepareAndStart(int attempt, {required bool replace}) async {
    bool overtaken() => _disposed || attempt != _attempt;

    // Taken together, before anything is waited for. The parts below have to agree
    // with each other, and by the time a slow mirror has answered a subscription may
    // have refreshed or a setting changed.
    final server = selected;
    final servers = _data.servers;
    final settings = _settings;
    final settingsEncoded = _settingsEncoded;
    if (server == null) {
      _fail(const ActionError(ActionErrorKind.noServer));
      return;
    }
    // Known-impossible up front. Letting this proceed would spend five seconds
    // reaching a handshake error that says nothing about the real cause.
    if (_refuse(server)) return;

    // The one server each other core will carry — not necessarily the selected one.
    // Running both for the whole session is what lets every server be measured and
    // switched to, rather than only the one that happened to be chosen at connect.
    final xrayServer = settings.xrayServerFor(server, servers);
    final amneziaServer = settings.amneziaServerFor(server, servers);
    if (server.requiresXray && xrayServer == null) {
      _fail(ActionError(ActionErrorKind.xrayUnconvertible, subject: server.tag));
      return;
    }
    // One set for this session, shared by every side of each loopback hand-off:
    // the core that listens and the sing-box outbound that dials it.
    final loopback = LoopbackAuth.random();
    final xrayConfig = xrayServer == null
        ? null
        : XrayConfig.build(xrayServer, tricks: settings.tlsTricks, loopback: loopback);

    // Rule sets must exist on disk before the config references them. Time-boxed:
    // a slow or unreachable mirror must delay the connect, not prevent it.
    await refreshRuleSets(within: const Duration(seconds: 12));
    if (overtaken()) return;

    try {
      // Consent is requested before anything is written, so a declined dialog
      // leaves no half-applied state behind.
      final allowed = await _channel.prepare();
      if (overtaken()) return;
      if (!allowed) {
        _fail(const ActionError(ActionErrorKind.vpnPermission));
        return;
      }
      await _channel.start(
        config: settings.build(
          server,
          servers: servers,
          ruleSetPaths: _ruleSetPaths,
          loopback: loopback,
        ),
        profileName: server.tag,
        xrayConfig: xrayConfig,
        // Passed verbatim; the core that reads it is the only thing that knows what
        // these parameters mean.
        amneziaConfig: amneziaServer?.amneziaConf,
        amneziaSocks: loopback,
        proxyLabel: _proxyLabel,
        directLabel: _directLabel,
        groupName: _subscriptionNameOf(server),
        replace: replace,
      );
      if (overtaken()) return;
      _appliedSettingsEncoded = settingsEncoded;
    } on TunnelException catch (e) {
      if (!overtaken()) _fail(e);
      return;
    }
    // With nothing chosen the first server stands in for it, and the first is whichever
    // one a refresh put there. What runs is written down as the choice, so that the next
    // refresh cannot read as one and move the tunnel somewhere else.
    if (_data.selectedTag == server.tag) return;
    if (servers.any((s) => s.tag == _data.selectedTag)) return;
    _data = _data.copyWith(selectedTag: server.tag);
    await _persist();
  }

  /// Says why a server cannot be used, and returns true, when it cannot.
  bool _refuse(Outbound server) {
    final problem = server.problem;
    if (problem == null) return false;
    _fail(ActionError(ActionErrorKind.serverUnsupported, subject: server.tag, problem: problem));
    return true;
  }

  /// Asks for a reconnect when the running tunnel was started from a config older
  /// than this version writes.
  ///
  /// After an update the service restarts itself from the config the previous
  /// version left on disk — through always-on VPN, auto-connect, or the supervisor —
  /// so whatever this version fixed in the config is not running until the next
  /// connect, and with always-on that can be weeks away. The reconnect prompt the
  /// app already shows for changed settings is the right thing to say.
  Future<void> _flagStaleRunningConfig() async {
    if (!_status.stage.isActive) return;
    try {
      if (await _channel.configVersion() >= ConfigBuilder.generatedConfigVersion) return;
    } on TunnelException {
      return;
    }
    // Anything unequal to the current settings: there is no record of what the
    // running config was built from, only that it was not built by this version.
    if (_appliedSettingsEncoded != null || !_status.stage.isActive) return;
    _appliedSettingsEncoded = '';
    notifyListeners();
  }

  /// Restarts the tunnel so changed settings take effect.
  ///
  /// The service does this in one step, with the TUN device left in place until the new
  /// tunnel has one of its own. Stopping and then starting took the device away in
  /// between, and for those seconds every app on the phone was on the bare network —
  /// which someone who switched the tunnel on to not be there has no way to see.
  ///
  /// A tunnel already on its way down is waited for, because the service would take the
  /// new one for a part of the old. [stopTimeout] is a ceiling, not a contract: a start
  /// that fails is visible and recoverable, while returning without one leaves a tunnel
  /// that is neither up nor coming up.
  Future<void> reconnect({Duration stopTimeout = const Duration(seconds: 10)}) async {
    if (_status.stage == TunnelStage.stopping) {
      final attempt = _attempt;
      await _awaitStopped(stopTimeout);
      // Connected or disconnected by hand while this waited. That is the newer wish.
      if (_disposed || attempt != _attempt) return;
    }
    await _start(replace: _status.stage != TunnelStage.stopped);
  }

  /// Waits for the tunnel to actually be down.
  ///
  /// Reads the status the existing subscription already keeps current rather than
  /// opening a second one: a listener attached after the event has been published
  /// waits for a "stopped" that has already happened and never comes again.
  Future<void> _awaitStopped(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_status.stage == TunnelStage.stopping) {
      if (!DateTime.now().isBefore(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> disconnect() async {
    // Anything still getting ready to start stops here.
    _attempt++;
    final preparing = isPreparing;
    _connecting = false;
    _appliedSettingsEncoded = null;
    if (preparing) notifyListeners();
    try {
      await _channel.stop();
    } on TunnelException catch (e) {
      _fail(e);
    }
  }

  Future<void> toggle() => _status.stage.isActive || isPreparing ? disconnect() : connect();

  // ---- latency & live switching -----------------------------------------

  /// Measures every server in the selector. Only possible while connected: the
  /// measurement is made by the running core, through the tunnel's own dialer.
  Future<void> testLatency() async {
    if (!_status.stage.isActive || _testing) return;
    _testing = true;
    _signal(groupsChanged);
    try {
      await _channel.urlTest();
    } on TunnelException catch (e) {
      _testing = false;
      _signal(groupsChanged);
      _fail(e);
    }
  }

  /// Makes the core agree with the app about which server is in use.
  ///
  /// sing-box's selector restores whatever outbound it last had from its cache file,
  /// and only falls back to the config's `default` when the cache holds nothing for
  /// it — `Selector.Start` returns as soon as the cached tag resolves. So a server
  /// chosen here and applied by reconnecting is silently overruled by whichever
  /// server was chosen before it: the app says one thing and the traffic goes
  /// somewhere else, with nothing to show for it but a second row in the list marked
  /// as the active one.
  ///
  /// The app is the source of truth. Every way a server can be chosen updates
  /// [selected] first, so correcting towards it can never fight a deliberate switch —
  /// after one, the two already agree and this does nothing.
  ///
  /// Only towards a server that was chosen. [selected] falls back to the first in the
  /// list when the chosen one is gone, and a refresh that renamed a server would then
  /// move a running tunnel to whichever one happened to come first.
  Future<void> _alignSelection() async {
    final group = proxyGroup;
    final wanted = _data.selectedTag;
    if (group == null || wanted == null || group.selected == wanted) return;
    if (!_data.servers.any((server) => server.tag == wanted)) return;
    // Not a member: a server that needs another core is only ever in the config when
    // it is the selected one, so this means the config is older than the choice and
    // a reconnect is already on its way.
    if (!group.items.any((item) => item.tag == wanted)) return;
    try {
      await _channel.selectOutbound(group: group.tag, outbound: wanted);
    } on TunnelException {
      // The next group report tries again. A core that will not take a selection has
      // worse problems, and they will show up somewhere with more to say than here.
    }
  }

  /// Measures the server that is actually carrying traffic, through the tunnel.
  ///
  /// The core cannot be asked for one server: its only measurement takes a whole
  /// group. This asks the other question instead — how long a round trip takes along
  /// the path in use — which is what someone means by "test this one", and which
  /// works for the servers the core cannot even include in a group, because they run
  /// on another core and are only ever present while they are the one in use.
  ///
  /// Kept apart from the core's readings rather than mixed in with them: it measures
  /// the whole path rather than the outbound alone, and the two are not the same
  /// number even when they are close.
  Future<void> testActiveLatency() async {
    final tag = activeTag ?? selected?.tag;
    if (!_status.stage.isActive || tag == null || _testing) return;
    _testing = true;
    _signal(groupsChanged);
    final latency = await const SpeedTest(samples: 3).latency();
    if (_disposed) return;
    _testing = false;
    _measured = {..._measured};
    if (latency == null) {
      _measured.remove(tag);
    } else {
      _measured[tag] = latency;
    }
    _signal(groupsChanged);
  }

  Map<String, Duration> _measured = const {};

  /// Round trips measured through the tunnel, by server tag. See [testActiveLatency].
  Map<String, Duration> get measuredLatency => _measured;

  Map<String, Duration> _reachability = const {};

  /// Time to open a TCP connection to each server's own address.
  ///
  /// The only measurement available with the tunnel down, and a different thing from
  /// the core's: nothing is negotiated and nothing is carried. Kept in its own map so
  /// it cannot be mistaken for a proxy round trip, and shown only where there is no
  /// better reading.
  Map<String, Duration> get reachability => _reachability;

  bool _probing = false;
  bool get isProbing => _probing;

  /// Measures every server a TCP probe can say anything about.
  ///
  /// Works whether or not the tunnel is up, which is the whole point of it. Servers
  /// carried over UDP are skipped rather than reported as unreachable: nothing is
  /// listening for a TCP handshake on a WireGuard port, and calling that a failure
  /// would be the measurement lying about what it measured.
  Future<void> probeReachability() async {
    if (_probing) return;
    _probing = true;
    _signal(groupsChanged);
    final targets = <String, ({String host, int port})>{
      for (final server in servers)
        if (server.isUsable && server.reachableOverTcp && server.server.isNotEmpty)
          server.tag: (host: server.server, port: server.serverPort),
    };
    final measured = await const Reachability().measureAll(targets);
    if (_disposed) return;
    _probing = false;
    _reachability = measured;
    _signal(groupsChanged);
  }

  /// Switches the live tunnel to another server without reconnecting.
  ///
  /// Falls back to a full reconnect when the target is not a member of the running
  /// config — an Xray-only server, since exactly one Xray instance runs at a time.
  ///
  /// Refuses a server that cannot be used, before anything else: with the tunnel up it
  /// is never in the running config, so going on meant a reconnect to a server known
  /// not to work — and a tunnel that was working gone.
  Future<void> switchTo(Outbound server) async {
    if (_refuse(server)) return;
    await select(server);
    if (!_status.stage.isActive) return;
    final group = proxyGroup;
    final canSwitchLive = group != null && group.items.any((item) => item.tag == server.tag);
    if (canSwitchLive) {
      try {
        await _channel.selectOutbound(group: group.tag, outbound: server.tag);
        return;
      } on TunnelException catch (e) {
        _fail(e);
        return;
      }
    }
    await reconnect();
  }

  // ---- backup -----------------------------------------------------------

  /// Everything the app knows, encrypted with [password], as base64 text.
  ///
  /// One line of text, so the same backup can be saved as a file or copied into a
  /// note or a password manager. It is encrypted because it carries every server's
  /// credentials and those places are rarely private.
  Future<String> exportBackup(String password) async {
    final payload = jsonEncode(_store.encode(_data));
    return _channel.encryptBackup(data: payload, password: password);
  }

  /// Replaces everything with the contents of a backup.
  ///
  /// All-or-nothing: the document is decrypted and parsed in full before anything
  /// is written, so a wrong password or a truncated paste cannot leave a half
  /// restored profile.
  Future<void> importBackup(String encoded, String password) async {
    final plaintext = await _channel.decryptBackup(data: encoded, password: password);
    final decoded = jsonDecode(plaintext);
    if (decoded is! Map) throw const FormatException('Backup content is not readable');
    final restored = _store.decode(decoded.cast<String, Object?>());

    _settings = (restored.settings ?? ConfigBuilder(routing: RoutingSettings.defaults))
        .withProxyCredentials();
    _data = restored.copyWith(settings: _settings);
    _settingsEncoded = jsonEncode(_settings.toJson());
    final code = restored.localeCode;
    localeListenable.value = code == null ? null : Locale(code);
    themeModeListenable.value = _themeModeOf(restored.themeModeName);
    await _store.save(_data);
    notifyListeners();
    unawaited(refreshRuleSets());
  }

  // ---- servers ----------------------------------------------------------

  Future<void> select(Outbound server) async {
    _data = _data.copyWith(selectedTag: server.tag);
    await _persist();
    // A live tunnel keeps running on the old server until the user reconnects;
    // silently restarting it would drop their connections without warning.
  }

  /// Accepts a share link, or a pasted WireGuard `.conf`.
  ///
  /// The file is not a link and never will be — it is what every WireGuard provider
  /// hands out, so the paste box takes it rather than making the user convert it.
  ///
  /// True when a server was added. Like the other ways in below, a failure is reported
  /// through [lastActionError]; the result is for a form deciding whether to close.
  Future<bool> addFromLink(String link) async {
    final parsed = ShareLink.parse(link) ?? WireGuardConfig.parse(link);
    if (parsed == null) {
      _fail(
        ActionError(
          WireGuardConfig.looksLikeConf(link)
              // It looked like the right thing and still failed, so say what is
              // missing rather than repeating that it is unsupported.
              ? ActionErrorKind.wireGuardIncomplete
              : ActionErrorKind.notALink,
        ),
      );
      return false;
    }
    await _addServers([parsed], selectFirst: _data.servers.isEmpty);
    return true;
  }

  /// Adds a hand-written sing-box outbound.
  ///
  /// Validated by the core before it is saved, in the same config shape it will run
  /// in. Catching it here means a typo surfaces as a parser message next to the text
  /// box, instead of a failed connection later with nothing pointing at the cause.
  Future<bool> addCustomOutbound(String source, {String? name}) async {
    final Outbound parsed;
    try {
      parsed = CustomOutbound.parse(source, name: name);
    } on FormatException catch (e) {
      _fail(e);
      return false;
    }
    try {
      final error = await _channel.validateConfig(
        _settings.build(parsed, servers: [parsed], ruleSetPaths: _ruleSetPaths),
      );
      if (error != null) {
        _fail(ActionError(ActionErrorKind.configRejected, detail: error));
        return false;
      }
    } on TunnelException catch (e) {
      _fail(e);
      return false;
    }
    await _addServers([parsed], selectFirst: _data.servers.isEmpty);
    return true;
  }

  Future<bool> importSubscription({required String name, required String url}) async {
    // The same address twice is the same servers twice, and nothing to gain: import
    // it again and the one already there is refreshed instead.
    final existing = _data.subscriptions.where((s) => s.url.trim() == url.trim()).firstOrNull;
    if (existing != null) return refreshSubscription(existing);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    try {
      final result = await SubscriptionFetcher(allowInsecure: _data.insecureDownloads)
          .fetch(url, subscriptionId: id);
      final subscription = Subscription(
        id: id,
        name: name.isEmpty ? Uri.tryParse(url)?.host ?? 'Subscription' : name,
        url: url,
        updatedAt: DateTime.now(),
        usage: result.usage,
      );
      _data = _data.copyWith(subscriptions: [..._data.subscriptions, subscription]);
      await _addServers(result.servers, selectFirst: _data.servers.isEmpty);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// How long a subscription may go unrefreshed before the app updates it on launch.
  static const _subscriptionMaxAge = Duration(hours: 12);

  /// Quietly refreshes stale subscriptions at startup.
  ///
  /// Failures are swallowed rather than reported: this runs without the user asking
  /// for it, and a provider being briefly unreachable is not something to interrupt
  /// them about. The existing servers keep working.
  Future<void> _autoRefreshSubscriptions() async {
    final now = DateTime.now();
    for (final subscription in [..._data.subscriptions]) {
      final updatedAt = subscription.updatedAt;
      if (updatedAt != null && now.difference(updatedAt) < _subscriptionMaxAge) continue;
      try {
        // _refresh, not refreshSubscription: the latter reports failures to the
        // user, which for a refresh nobody asked for means an error snackbar on
        // launch every time the device happens to be offline.
        await _refresh(subscription);
      } catch (_) {
        // Deliberately silent; see above.
      }
    }
  }

  /// Refreshes and reports the failure to the user. For a refresh the user asked for.
  Future<bool> refreshSubscription(Subscription subscription) async {
    try {
      await _refresh(subscription);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// Refreshes, and throws if it cannot.
  Future<void> _refresh(Subscription subscription) async {
    final result = await SubscriptionFetcher(allowInsecure: _data.insecureDownloads)
        .fetch(subscription.url, subscriptionId: subscription.id);
    // Removed while it was being fetched. Its servers would come back belonging to a
    // subscription that no longer exists, with nothing left to remove them by.
    if (!_data.subscriptions.any((s) => s.id == subscription.id)) return;
    // Replace this subscription's servers wholesale; a refresh is authoritative.
    final kept = _data.servers.where((s) => s.subscriptionId != subscription.id).toList();
    _data = _data.copyWith(
      // The fresh list is unique only within itself. Another subscription, or a
      // server added by hand, can hold the same names, and those keep theirs.
      servers: Outbound.withUniqueTags([...kept, ...result.servers]),
      subscriptions: _data.subscriptions
          .map(
            (s) => s.id == subscription.id
                ? s.copyWith(
                    updatedAt: DateTime.now(),
                    // Keep the previous figures when a provider reports nothing,
                    // rather than blanking a reading the user could still use.
                    usage: result.usage.isEmpty ? s.usage : result.usage,
                  )
                : s,
          )
          .toList(),
    );
    await _persist();
  }

  Future<void> removeSubscription(Subscription subscription) async {
    _data = _data.copyWith(
      servers: _data.servers.where((s) => s.subscriptionId != subscription.id).toList(),
      subscriptions: _data.subscriptions.where((s) => s.id != subscription.id).toList(),
    );
    await _persist();
  }

  /// Re-fetches every subscription, which is what repopulates the share links that
  /// older profiles never stored.
  Future<void> refreshAllSubscriptions() async {
    for (final subscription in [..._data.subscriptions]) {
      await refreshSubscription(subscription);
    }
    _data = _data.copyWith(needsReimport: false);
    await _persist();
  }

  /// Dismisses the stale-profile notice without refreshing, for users who have no
  /// subscriptions to refresh.
  Future<void> dismissReimportNotice() async {
    _data = _data.copyWith(needsReimport: false);
    await _persist();
  }

  /// Removes a server and reports where it was, so [restoreServer] can put it back.
  ///
  /// Returns -1 when the server was not in the list, which happens if the row was
  /// tapped twice before the first removal settled.
  Future<int> removeServer(Outbound server) async {
    final index = _data.servers.indexWhere((s) => s.tag == server.tag);
    if (index < 0) return -1;
    _data = _data.copyWith(servers: _data.servers.where((s) => s.tag != server.tag).toList());
    await _persist();
    // Its recorded traffic goes with it. A total left behind would reattach itself
    // to the next server that happened to take the same name.
    _serverUsage = {..._serverUsage}..remove(server.tag);
    try {
      await _channel.forgetServerUsage(server.tag);
    } on TunnelException {
      // Non-Android, or the service is not up. The entry is already gone from the
      // list, and the file is capped, so nothing is left to go wrong.
    }
    return index;
  }

  /// Puts a removed server back where it was, for the undo action on the snackbar.
  ///
  /// The recorded traffic is not restored with it: the service was told to forget
  /// that total, and inventing one here would be worse than the counter starting
  /// again. Re-adding a tag that has since come back — a subscription refresh landed
  /// while the snackbar was up — is skipped rather than duplicated.
  Future<void> restoreServer(Outbound server, int index) async {
    if (_data.servers.any((s) => s.tag == server.tag)) return;
    final servers = [..._data.servers];
    servers.insert(index.clamp(0, servers.length), server);
    _data = _data.copyWith(servers: servers);
    await _persist();
  }

  /// The exact sing-box config the selected server would run, pretty-printed by the
  /// core itself. Being able to see this is the difference between debugging a
  /// connection and guessing at it.
  Future<String> generatedConfig() async {
    final server = selected;
    if (server == null) return '';
    final raw = _settings.build(server, servers: servers, ruleSetPaths: _ruleSetPaths);
    try {
      return await _channel.formatConfig(raw);
    } on TunnelException {
      // Formatting is a convenience; the config itself is still worth showing.
      return raw;
    }
  }

  Future<void> updateSettings(ConfigBuilder settings) async {
    // Every way into the settings passes here, so a login switched on anywhere is a
    // login with credentials behind it.
    settings = settings.withProxyCredentials();
    _settings = settings;
    _settingsEncoded = jsonEncode(settings.toJson());
    _data = _data.copyWith(settings: settings);
    await _persist();
  }

  // ---- routing ----------------------------------------------------------

  RoutingSettings get routing => _settings.routing;

  /// Presets whose rule set is downloaded and ready, keyed by preset id.
  Map<String, String> _ruleSetPaths = const {};

  /// Whether a rule-set download is in flight, wherever it was started from.
  ///
  /// A count rather than a flag, because these overlap: the button on the routing
  /// screen, switching a preset on, and connecting all start one, and with a flag
  /// the first to finish would declare the others over too.
  bool get isUpdatingRuleSets => _ruleSetRefreshes > 0;
  int _ruleSetRefreshes = 0;

  /// Presets the last download attempt could not provide. They are dropped from the
  /// config rather than referenced, because sing-box refuses to start when a rule
  /// set file is missing.
  List<RuleSetPreset> _unavailablePresets = const [];
  List<RuleSetPreset> get unavailablePresets => UnmodifiableListView(_unavailablePresets);

  Future<void> addRule(RoutingRule rule) =>
      updateSettings(_withRouting(routing.copyWith(rules: [...routing.rules, rule])));

  /// Replaces one rule in place.
  ///
  /// Editing rather than delete-and-retype matters because the rule's position is
  /// part of its meaning: the core takes the first match, so a rule that moves to
  /// the end of the list can stop applying without its own text changing.
  Future<void> updateRuleAt(int index, RoutingRule rule) {
    if (index < 0 || index >= routing.rules.length) return Future<void>.value();
    final rules = [...routing.rules];
    rules[index] = rule;
    return updateSettings(_withRouting(routing.copyWith(rules: rules)));
  }

  Future<void> removeRuleAt(int index) {
    final rules = [...routing.rules]..removeAt(index);
    return updateSettings(_withRouting(routing.copyWith(rules: rules)));
  }

  /// Puts a swiped-away rule back at its old position, for the undo action.
  ///
  /// Order is the whole meaning of a rule list — the core takes the first match — so
  /// a restore that appended would quietly change what the rule does.
  Future<void> restoreRuleAt(int index, RoutingRule rule) {
    final rules = [...routing.rules]..insert(index.clamp(0, routing.rules.length), rule);
    return updateSettings(_withRouting(routing.copyWith(rules: rules)));
  }

  Future<void> toggleRuleAt(int index, bool enabled) {
    final rules = [...routing.rules];
    rules[index] = rules[index].copyWith(enabled: enabled);
    return updateSettings(_withRouting(routing.copyWith(rules: rules)));
  }

  // ---- WARP -------------------------------------------------------------

  bool _registeringWarp = false;
  bool get isRegisteringWarp => _registeringWarp;

  /// Registers a free Cloudflare WARP account and enables it.
  ///
  /// Registration is a one-off network call to Cloudflare; the account is then kept
  /// with the profile, so this is not repeated on every connect.
  Future<void> enableWarp() async {
    if (_registeringWarp) return;
    _registeringWarp = true;
    notifyListeners();
    try {
      final account = await WarpRegistration(generateKeyPair: _channel.generateWireGuardKey)
          .register();
      await updateSettings(_withRouting(routing.copyWith(warp: account)));
    } catch (e) {
      _fail(ActionError(ActionErrorKind.warpRegistration, cause: ActionError.from(e)));
    } finally {
      _registeringWarp = false;
      notifyListeners();
    }
  }

  Future<void> disableWarp() => updateSettings(_withRouting(routing.copyWith(clearWarp: true)));

  /// Attaches a WARP+ licence key. Returns null on success, or why it was refused.
  ///
  /// Reported to the caller rather than through [lastActionError] because the key is
  /// entered in a dialog, and an answer that appears behind it is no answer.
  Future<ActionError?> applyWarpLicense(String license) async {
    final account = routing.warp;
    if (account == null) return const ActionError(ActionErrorKind.warpNotOn);
    try {
      final upgraded = await WarpRegistration(generateKeyPair: _channel.generateWireGuardKey)
          .applyLicense(account, license);
      await updateSettings(_withRouting(routing.copyWith(warp: upgraded)));
      return null;
    } catch (e) {
      return ActionError.from(e);
    }
  }

  /// Points WARP at another Cloudflare address. Empty and 0 mean the registered one.
  Future<void> setWarpEndpoint({String? host, int? port}) =>
      updateSettings(_withRouting(routing.copyWith(warpEndpoint: host, warpPort: port)));

  /// Chained through the proxy, or straight out on its own.
  Future<void> setWarpThroughProxy(bool value) =>
      updateSettings(_withRouting(routing.copyWith(warpThroughProxy: value)));

  /// Whether everything leaves through WARP rather than only what a rule sends there.
  Future<void> setWarpForAll(bool value) =>
      updateSettings(_withRouting(routing.copyWith(warpForAll: value)));

  /// Switches where rule sets come from, and re-fetches with the new one.
  ///
  /// Forced, because the files already on disk came from the old source and the whole
  /// reason to change it is that the old one could not be reached.
  Future<void> setRuleSetSource(String source, {String base = ''}) async {
    await updateSettings(_withRouting(routing.copyWith(ruleSetSource: source, ruleSetBase: base)));
    await refreshRuleSets(force: true);
  }

  Future<void> togglePreset(RuleSetPreset preset, bool enabled) async {
    final ids = {...routing.enabledPresets};
    if (enabled) {
      ids.add(preset.id);
    } else {
      ids.remove(preset.id);
    }
    await updateSettings(_withRouting(routing.copyWith(enabledPresets: ids)));
    if (enabled) await refreshRuleSets();
  }

  /// Downloads any rule sets that are missing or stale.
  ///
  /// Done here rather than by sing-box because a failed *initial* remote fetch
  /// aborts service start outright: an unreachable GitHub would mean the tunnel
  /// refuses to come up at all, instead of simply routing without that list.
  Future<void> refreshRuleSets({bool force = false, Duration? within}) async {
    final presets = routing.activePresets;
    if (presets.isEmpty) {
      _ruleSetPaths = const {};
      _unavailablePresets = const [];
      notifyListeners();
      return;
    }
    _ruleSetRefreshes++;
    notifyListeners();
    try {
      _unavailablePresets = await RuleSetStore.instance.ensureAvailable(
        presets,
        force: force,
        within: within,
        source: routing.ruleSetSource,
        base: routing.ruleSetBase,
        allowInsecure: _data.insecureDownloads,
      );
      _ruleSetPaths = await RuleSetStore.instance.localPaths(presets);
      if (_unavailablePresets.isNotEmpty) {
        _fail(
          ActionError(
            ActionErrorKind.ruleSetsUnavailable,
            subject: _unavailablePresets.map((e) => e.id).join(','),
          ),
        );
      }
    } finally {
      // In a finally because the alternative is a spinner that never stops: a
      // download that throws would otherwise leave the count raised for the life of
      // the app, and the screen has no other way to learn it is over.
      _ruleSetRefreshes--;
      if (!_disposed) notifyListeners();
    }
  }

  ConfigBuilder _withRouting(RoutingSettings value) => _settings.copyWith(routing: value);

  void clearActionError() {
    if (_lastActionError == null) return;
    _lastActionError = null;
    notifyListeners();
  }

  /// The last failure, handed to a caller that shows it where the work was asked for.
  /// Left alone it becomes the shell's message, which is out of sight under a sheet.
  ActionError? takeActionError() {
    final error = _lastActionError;
    clearActionError();
    return error;
  }

  // ---- internals --------------------------------------------------------

  Future<void> _addServers(List<Outbound> incoming, {required bool selectFirst}) async {
    // Existing servers first, so they keep their names and a newcomer gets the suffix.
    final merged = Outbound.withUniqueTags([..._data.servers, ...incoming]);
    _data = _data.copyWith(
      servers: merged,
      selectedTag: selectFirst && merged.isNotEmpty ? merged.first.tag : _data.selectedTag,
    );
    await _persist();
  }

  Future<void> _persist() async {
    notifyListeners();
    try {
      await _store.save(_data);
    } catch (e) {
      _fail(ActionError(ActionErrorKind.saveFailed, cause: ActionError.from(e)));
    }
  }

  /// Records a failure for the shell to report. Takes the exception itself, or an
  /// [ActionError] already saying what was being attempted; the sentence is built
  /// in the UI, in the user's language.
  void _fail(Object error) {
    _lastActionError = ActionError.from(error);
    notifyListeners();
  }
}

/// A [Listenable] with nothing to read: listeners are told something changed and go
/// look at the controller themselves.
///
/// Exists so the streams that publish once a second do not have to share the one
/// notifier the whole widget tree listens to.
class _Signal extends ChangeNotifier {
  void ping() => notifyListeners();
}
