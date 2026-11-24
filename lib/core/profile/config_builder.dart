import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'loopback_auth.dart';
import 'multiplex.dart';
import 'outbound.dart';
import 'routing.dart';
import 'xray_config.dart';

/// One member of the proxy group, and which of the config's two arrays it belongs in.
///
/// WireGuard servers are written to `endpoints` and everything else to `outbounds`,
/// but both share one tag namespace — so the selector and the latency test are built
/// from the same list and neither needs to know which is which.
typedef _Member = ({
  String tag,
  bool isEndpoint,
  Map<String, Object?> json,

  /// Already tagged, and already wired to each other and to [json] by `detour`.
  List<Map<String, Object?>> chain,
});

/// Which traffic goes through the tunnel.
enum RoutingMode {
  /// Everything except private/LAN destinations.
  global,

  /// Bypass the local network and let everything else out through the proxy.
  bypassLan,
}

/// Per-app tunnelling. Android applies exactly one of these, never both.
class PerAppRules {
  const PerAppRules({this.mode = PerAppMode.off, this.packages = const []});

  final PerAppMode mode;
  final List<String> packages;

  bool get isActive => mode != PerAppMode.off && packages.isNotEmpty;
}

enum PerAppMode { off, include, exclude }

/// Assembles the sing-box config the core actually runs.
///
/// The app stores servers as bare outbounds; everything around them — the TUN
/// inbound, DNS, routing — is generated here so a config can never drift out of sync
/// with the app's settings. Nothing here is user-editable yet, which is deliberate:
/// a hand-edited config that no longer matches the UI is the single biggest source of
/// "it says connected but nothing works" reports in clients of this kind.
class ConfigBuilder {
  const ConfigBuilder({
    this.routingMode = RoutingMode.bypassLan,
    this.perApp = const PerAppRules(),
    this.mtu = 9000,
    this.enableIpv6 = false,
    this.logLevel = 'info',
    this.remoteDns = 'tls://1.1.1.1',
    this.directDns = '',
    this.domainStrategy = strategyAuto,
    this.tunStack = 'mixed',
    this.strictRoute = true,
    this.fakeDns = false,
    this.resolveDestination = false,
    this.testUrl = defaultTestUrl,
    this.testIntervalMinutes = 3,
    this.mixedPort = 0,
    this.directPort = 0,
    this.shareInLocalNetwork = false,
    this.localProxyAuth = true,
    this.localProxyUsername = '',
    this.localProxyPassword = '',
    this.clashApiPort = 0,
    this.clashApiSecret = '',
    this.serverAddressStrategy = strategyAuto,
    this.allowInsecure = false,
    this.sniffing = true,
    this.httpProxyForVpn = false,
    this.tlsTricks = const TlsTricks(),
    this.multiplex = const MultiplexSettings(),
    this.routing = const RoutingSettings(),
  });

  final RoutingMode routingMode;
  final PerAppRules perApp;
  final int mtu;
  final bool enableIpv6;
  final String logLevel;
  final String remoteDns;

  /// Resolver for the proxy server's own hostname, which has to be looked up before
  /// any tunnel exists. Empty means the platform resolver — whatever DNS the current
  /// network handed out — which is the right default: a fixed public resolver fails
  /// wherever it is blocked, and that is exactly where this app gets used.
  final String directDns;

  /// How hostnames resolve to addresses. [strategyAuto] follows the IPv6 setting.
  final String domainStrategy;

  /// Which TUN implementation carries the traffic. `mixed` is gVisor for TCP with the
  /// system stack for UDP — the combination that behaves across the range of Android
  /// kernels. `system` is faster and less forgiving; `gvisor` is the safest.
  final String tunStack;

  /// Stops other apps escaping the tunnel with their own bypass.
  ///
  /// sing-box hands this to the platform rather than acting on it: we open the TUN,
  /// so honouring it means not granting `allowBypass()` on the VpnService builder.
  ///
  /// On by default. Granting the bypass lets any app bind to the underlying network
  /// on purpose and read the real address — which is precisely what VPN detection
  /// does. The cost of withholding it falls on the rare app that needs to talk to a
  /// network directly, such as one setting up a device over its own WIFI hotspot.
  final bool strictRoute;

  /// Hand out placeholder addresses instead of waiting for a real lookup.
  ///
  /// Removes the DNS round trip before a connection and keeps the real hostname all
  /// the way to routing, so domain rules still match. The cost is that anything
  /// reading the address rather than the name — a raw IP connection, some VPN
  /// detection — sees an address that does not exist.
  final bool fakeDns;

  /// Resolve a destination hostname before the IP rules are evaluated.
  ///
  /// Without it an IP-based rule set cannot match a connection made by name, because
  /// at that point there is no address to compare.
  final bool resolveDestination;

  /// What the latency test fetches. Must answer fast and with an empty body.
  final String testUrl;

  /// How often the `auto` group re-measures its members.
  final int testIntervalMinutes;

  /// A local SOCKS/HTTP proxy on this port, or 0 for none.
  ///
  /// Separate from the TUN: apps that can be pointed at a proxy directly avoid the
  /// TUN round trip entirely, and it is the only way to proxy a device that cannot
  /// run a VPN of its own.
  final int mixedPort;

  /// A second local proxy whose traffic is forced out direct, or 0 for none.
  /// Useful as an escape hatch for one app while everything else is tunnelled.
  final int directPort;

  /// Listen on every interface rather than loopback, so other devices on the network
  /// can use the local proxies above.
  final bool shareInLocalNetwork;

  /// The local proxies demand [localProxyUsername] and [localProxyPassword].
  ///
  /// Loopback is reachable by every app on the device, including the ones kept out of
  /// the tunnel, and with [shareInLocalNetwork] the proxies are on the network too.
  /// Open, either one lets anything route through the tunnel and learn where it
  /// exits. On by default; a proxy someone already pointed apps at before this
  /// existed stays open until they turn it on, rather than silently breaking.
  final bool localProxyAuth;

  /// Minted once, by [withProxyCredentials], and kept: apps configured with them
  /// should keep working across reconnects.
  final String localProxyUsername;
  final String localProxyPassword;

  /// Whether the local proxies will actually ask for a login. False when the
  /// credentials are missing, which [build] treats by not opening the proxies at all
  /// rather than opening them without one.
  bool get localProxyLocked =>
      localProxyAuth && localProxyUsername.isNotEmpty && localProxyPassword.isNotEmpty;

  /// Fills in credentials when a local proxy is open, wants a login and has none yet;
  /// otherwise returns this unchanged, so calling it on every save costs nothing.
  ConfigBuilder withProxyCredentials() {
    if (!localProxyAuth || localProxyLocked || (mixedPort <= 0 && directPort <= 0)) return this;
    final random = Random.secure();
    // No 0/o or 1/l: these get typed into other apps by hand.
    const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    String pick(int length) =>
        List.generate(length, (_) => alphabet[random.nextInt(alphabet.length)]).join();
    return copyWith(localProxyUsername: 'trefoil-${pick(4)}', localProxyPassword: pick(20));
  }

  /// Whether Android is handed the local proxy. Its proxy setting has no field for a
  /// login, so a locked proxy is never handed over: the apps that would have used it
  /// go through the TUN instead, which costs a round trip and is otherwise the same.
  bool get handsProxyToAndroid => httpProxyForVpn && mixedPort > 0 && !localProxyAuth;

  /// Clash-compatible control API on this port, or 0 to keep it closed.
  ///
  /// Off by default and deliberately so: the API can select outbounds and read every
  /// connection, and on Android any app on the device can reach loopback. It is only
  /// worth opening to drive an external dashboard, and it is gated by a secret.
  final int clashApiPort;

  /// Gates the control API. Generated once when the port is first opened and kept,
  /// so a dashboard configured against it does not stop working on every reconnect.
  final String clashApiSecret;

  /// How the proxy server's own hostname is resolved, overriding [domainStrategy].
  ///
  /// Worth separating from the global setting because it is answered on the local
  /// network, before any tunnel exists — so whether that network speaks IPv6 has
  /// nothing to do with whether the tunnel will.
  ///
  /// sing-box has no equivalent per-resolver setting for the remote and direct
  /// servers: `strategy` on a DNS server was removed after 1.11, and only the global
  /// one and this remain.
  final String serverAddressStrategy;

  /// Skip TLS certificate verification on every outbound that uses TLS.
  ///
  /// Off by default, and it is worth being plain about what it turns off: with this
  /// on, anything positioned between the device and the server can present its own
  /// certificate and read the traffic, and the tunnel will accept it without
  /// complaint. It exists because a self-signed certificate on a server you run
  /// yourself is a real situation, and a share link can already ask for this per
  /// server — this applies the same thing to all of them at once.
  final bool allowInsecure;

  /// Read the protocol off each connection to recover the hostname.
  ///
  /// Every domain rule depends on it: without sniffing there is no name to match,
  /// only an address, so a rule list keyed on domains stops applying entirely. The
  /// cost is that the core reads the first bytes of every connection.
  final bool sniffing;

  /// Hand the local proxy to Android as the system HTTP proxy for the VPN.
  ///
  /// Apps that honour it — browsers, most things using the platform HTTP stack —
  /// then talk to the proxy directly instead of going through the TUN device, which
  /// skips a whole packet round trip. Requires [mixedPort]; Android 10+.
  final bool httpProxyForVpn;

  /// Handshake-splitting, applied only on the Xray path. See [TlsTricks].
  final TlsTricks tlsTricks;

  /// Stream multiplexing, applied to the outbounds that support it. See
  /// [MultiplexSettings].
  final MultiplexSettings multiplex;

  final RoutingSettings routing;

  /// A fresh API secret. Long enough that guessing it is not the weak point, and
  /// from a cryptographic source because the whole value of the port being gated
  /// rests on this being unpredictable.
  static String generateApiSecret() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(32, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  static const strategyAuto = 'auto';

  /// The values sing-box accepts for a DNS strategy, plus [strategyAuto].
  static const domainStrategies = [
    strategyAuto,
    'prefer_ipv4',
    'prefer_ipv6',
    'ipv4_only',
    'ipv6_only',
  ];

  static const tunStacks = ['mixed', 'system', 'gvisor'];

  /// sing-box's log levels, quietest first.
  static const logLevels = ['panic', 'fatal', 'error', 'warn', 'info', 'debug', 'trace'];

  /// The three quick modes, matched by sing-box's `clash_mode` rule field.
  ///
  /// Switching between them is instant and needs no reconnect: the rules for all
  /// three are already in the running config, and only which one matches changes.
  static const modeRule = 'Rule';
  static const modeGlobal = 'Global';
  static const modeDirect = 'Direct';

  /// Generates a 204 with an empty body, so a latency measurement is not skewed by
  /// download size.
  static const defaultTestUrl = 'https://www.gstatic.com/generate_204';

  /// Ranges sing-box itself documents for fake DNS. Inside the reserved
  /// benchmarking block, so they cannot collide with anything routable.
  static const fakeIpV4Range = '198.18.0.0/15';
  static const fakeIpV6Range = 'fc00::/18';
  static const dnsFakeTag = 'dns-fake';

  /// Copies with overrides.
  ///
  /// Rebuilding this object field-by-field at the call sites was a mistake: a field
  /// added later is simply left at its default there, silently discarding whatever
  /// the user had set. That is exactly how routing was dropped the first time.
  ConfigBuilder copyWith({
    RoutingMode? routingMode,
    PerAppRules? perApp,
    int? mtu,
    bool? enableIpv6,
    String? logLevel,
    String? remoteDns,
    String? directDns,
    String? domainStrategy,
    String? tunStack,
    bool? strictRoute,
    bool? fakeDns,
    bool? resolveDestination,
    String? testUrl,
    int? testIntervalMinutes,
    int? mixedPort,
    int? directPort,
    bool? shareInLocalNetwork,
    bool? localProxyAuth,
    String? localProxyUsername,
    String? localProxyPassword,
    int? clashApiPort,
    String? clashApiSecret,
    String? serverAddressStrategy,
    bool? allowInsecure,
    bool? sniffing,
    bool? httpProxyForVpn,
    TlsTricks? tlsTricks,
    MultiplexSettings? multiplex,
    RoutingSettings? routing,
  }) => ConfigBuilder(
    routingMode: routingMode ?? this.routingMode,
    perApp: perApp ?? this.perApp,
    mtu: mtu ?? this.mtu,
    enableIpv6: enableIpv6 ?? this.enableIpv6,
    logLevel: logLevel ?? this.logLevel,
    remoteDns: remoteDns ?? this.remoteDns,
    directDns: directDns ?? this.directDns,
    domainStrategy: domainStrategy ?? this.domainStrategy,
    tunStack: tunStack ?? this.tunStack,
    strictRoute: strictRoute ?? this.strictRoute,
    fakeDns: fakeDns ?? this.fakeDns,
    resolveDestination: resolveDestination ?? this.resolveDestination,
    testUrl: testUrl ?? this.testUrl,
    testIntervalMinutes: testIntervalMinutes ?? this.testIntervalMinutes,
    mixedPort: mixedPort ?? this.mixedPort,
    directPort: directPort ?? this.directPort,
    shareInLocalNetwork: shareInLocalNetwork ?? this.shareInLocalNetwork,
    localProxyAuth: localProxyAuth ?? this.localProxyAuth,
    localProxyUsername: localProxyUsername ?? this.localProxyUsername,
    localProxyPassword: localProxyPassword ?? this.localProxyPassword,
    clashApiPort: clashApiPort ?? this.clashApiPort,
    clashApiSecret: clashApiSecret ?? this.clashApiSecret,
    serverAddressStrategy: serverAddressStrategy ?? this.serverAddressStrategy,
    allowInsecure: allowInsecure ?? this.allowInsecure,
    sniffing: sniffing ?? this.sniffing,
    httpProxyForVpn: httpProxyForVpn ?? this.httpProxyForVpn,
    tlsTricks: tlsTricks ?? this.tlsTricks,
    multiplex: multiplex ?? this.multiplex,
    routing: routing ?? this.routing,
  );

  /// Round-trips the whole settings object.
  ///
  /// These were previously in-memory only, so routing mode, per-app rules and IPv6
  /// silently reverted on every app restart.
  Map<String, Object?> toJson() => {
    'settingsVersion': settingsVersion,
    'routingMode': routingMode.name,
    'perAppMode': perApp.mode.name,
    'perAppPackages': perApp.packages,
    'mtu': mtu,
    'enableIpv6': enableIpv6,
    'logLevel': logLevel,
    'remoteDns': remoteDns,
    'directDns': directDns,
    'domainStrategy': domainStrategy,
    'tunStack': tunStack,
    'strictRoute': strictRoute,
    'fakeDns': fakeDns,
    'resolveDestination': resolveDestination,
    'testUrl': testUrl,
    'testIntervalMinutes': testIntervalMinutes,
    'mixedPort': mixedPort,
    'directPort': directPort,
    'shareInLocalNetwork': shareInLocalNetwork,
    'localProxyAuth': localProxyAuth,
    'localProxyUsername': localProxyUsername,
    'localProxyPassword': localProxyPassword,
    'clashApiPort': clashApiPort,
    'clashApiSecret': clashApiSecret,
    'serverAddressStrategy': serverAddressStrategy,
    'allowInsecure': allowInsecure,
    'sniffing': sniffing,
    'httpProxyForVpn': httpProxyForVpn,
    'tlsTricks': tlsTricks.toJson(),
    'multiplex': multiplex.toJson(),
    'routing': routing.toJson(),
  };

  /// Bumped when a default changes for people who already have settings, and read
  /// back by [ConfigBuilder.fromJson] to apply that change exactly once.
  ///
  /// 2: [strictRoute] on, and [localProxyAuth] on unless a local proxy was already in
  /// use without it.
  static const settingsVersion = 2;

  /// Bumped when the generated config changes in a way a running tunnel has to be
  /// restarted to pick up — a fix that lives in the config does nothing until then.
  /// The native side records which one the running tunnel was started from.
  ///
  /// 2: authenticated loopback hand-off to the other cores, strict route by default.
  /// 3: rules apply in the order they are listed.
  static const generatedConfigVersion = 3;

  /// Settings written before versioning existed are version 1.
  static bool _predatesVersion2(Map<String, Object?> map) =>
      ((map['settingsVersion'] as num?)?.toInt() ?? 1) < 2;

  /// A local proxy some app may already be pointed at without a login. Android's own
  /// proxy setting cannot carry one either.
  static bool _hadOpenProxy(Map<String, Object?> map) =>
      ((map['mixedPort'] as num?)?.toInt() ?? 0) > 0 ||
      ((map['directPort'] as num?)?.toInt() ?? 0) > 0 ||
      (map['httpProxyForVpn'] as bool? ?? false);

  factory ConfigBuilder.fromJson(Map<String, Object?> map) => ConfigBuilder(
    routingMode: RoutingMode.values.firstWhere(
      (e) => e.name == map['routingMode'],
      orElse: () => RoutingMode.bypassLan,
    ),
    perApp: PerAppRules(
      mode: PerAppMode.values.firstWhere(
        (e) => e.name == map['perAppMode'],
        orElse: () => PerAppMode.off,
      ),
      packages: (map['perAppPackages'] as List? ?? []).cast<String>(),
    ),
    mtu: (map['mtu'] as num?)?.toInt() ?? 9000,
    enableIpv6: map['enableIpv6'] as bool? ?? false,
    logLevel: map['logLevel'] as String? ?? 'info',
    remoteDns: map['remoteDns'] as String? ?? 'tls://1.1.1.1',
    // Absent in profiles written before these were exposed; the defaults are what
    // those profiles were already running with.
    directDns: map['directDns'] as String? ?? '',
    domainStrategy: map['domainStrategy'] as String? ?? strategyAuto,
    tunStack: map['tunStack'] as String? ?? 'mixed',
    // Version 1 stored false for everyone: it was the default, and almost no one had
    // opened the screen that changes it. Read as that default rather than a choice,
    // and moved to the safe one once; from version 2 on it is a choice.
    strictRoute: _predatesVersion2(map) || (map['strictRoute'] as bool? ?? true),
    fakeDns: map['fakeDns'] as bool? ?? false,
    resolveDestination: map['resolveDestination'] as bool? ?? false,
    testUrl: map['testUrl'] as String? ?? defaultTestUrl,
    testIntervalMinutes: (map['testIntervalMinutes'] as num?)?.toInt() ?? 3,
    mixedPort: (map['mixedPort'] as num?)?.toInt() ?? 0,
    directPort: (map['directPort'] as num?)?.toInt() ?? 0,
    shareInLocalNetwork: map['shareInLocalNetwork'] as bool? ?? false,
    // A proxy already in use without a login stays that way until changed here,
    // rather than every app pointed at it failing at once after an update.
    localProxyAuth: _predatesVersion2(map)
        ? !_hadOpenProxy(map)
        : map['localProxyAuth'] as bool? ?? true,
    localProxyUsername: map['localProxyUsername'] as String? ?? '',
    localProxyPassword: map['localProxyPassword'] as String? ?? '',
    clashApiPort: (map['clashApiPort'] as num?)?.toInt() ?? 0,
    clashApiSecret: map['clashApiSecret'] as String? ?? '',
    serverAddressStrategy: map['serverAddressStrategy'] as String? ?? strategyAuto,
    allowInsecure: map['allowInsecure'] as bool? ?? false,
    sniffing: map['sniffing'] as bool? ?? true,
    httpProxyForVpn: map['httpProxyForVpn'] as bool? ?? false,
    tlsTricks: map['tlsTricks'] == null
        ? const TlsTricks()
        : TlsTricks.fromJson((map['tlsTricks'] as Map).cast<String, Object?>()),
    // Absent in profiles written before mux existed, which must read back as off.
    multiplex: map['multiplex'] == null
        ? const MultiplexSettings()
        : MultiplexSettings.fromJson((map['multiplex'] as Map).cast<String, Object?>()),
    routing: map['routing'] == null
        ? RoutingSettings.defaults
        : RoutingSettings.fromJson((map['routing'] as Map).cast<String, Object?>()),
  );

  /// The selector every route rule points at. Its members are the servers, so the
  /// user can switch between them without the config changing at all.
  static const proxyTag = 'proxy';

  /// Cloudflare WARP, present only once an account has been registered.
  static const warpTag = 'warp';

  /// A urltest group inside the selector, so "fastest" is a choice like any server.
  static const autoTag = 'auto';
  static const directTag = 'direct';

  static const dnsRemoteTag = 'dns-remote';
  static const dnsDirectTag = 'dns-direct';
  static const mixedInTag = 'mixed-in';
  static const directInTag = 'direct-in';

  /// [ruleSetPaths] maps preset ids to downloaded `.srs` files. Presets missing from
  /// it are left out entirely: sing-box treats a rule set whose file is absent as a
  /// fatal config error, so referencing one we failed to download would stop the
  /// tunnel from starting at all.
  ///
  /// [loopback] must be the same set the other cores were configured with, or the
  /// hand-off to them is refused; see [LoopbackAuth]. Left out, a fresh set is drawn,
  /// which suits a config that is only being shown or validated.
  String build(
    Outbound selected, {
    List<Outbound> servers = const [],
    Map<String, String> ruleSetPaths = const {},
    LoopbackAuth? loopback,
  }) => const JsonEncoder.withIndent(
    '  ',
  ).convert(buildMap(selected, servers: servers, ruleSetPaths: ruleSetPaths, loopback: loopback));

  /// [servers] is the full list, so the core can measure and switch between them
  /// without a reconnect. Only the ones sing-box can run natively are included;
  /// see [_proxyOutbounds] for why.
  Map<String, Object?> buildMap(
    Outbound selected, {
    List<Outbound> servers = const [],
    Map<String, String> ruleSetPaths = const {},
    LoopbackAuth? loopback,
  }) {
    final members = _proxyMembers(selected, servers, loopback ?? LoopbackAuth.random());
    // WireGuard servers go in `endpoints`, everything else in `outbounds`. They
    // share one tag namespace, so the selector and the latency test list them
    // together and neither knows the difference.
    final outbounds = [
      for (final m in members) ...[
        if (!m.isEndpoint) m.json,
        // The links a chained server dials through. Real outbounds with real tags,
        // but never members: nothing routes to them, and putting one in the selector
        // would offer the user "the TLS half of that server" as somewhere to connect.
        ...m.chain,
      ],
    ];
    final endpoints = [
      for (final m in members)
        if (m.isEndpoint) m.json,
    ];
    final memberTags = members.map((e) => e.tag).toList();

    return {
      'log': {'level': logLevel, 'timestamp': true},
      'dns': _dns(),
      'inbounds': [_tunInbound(), ..._localInbounds()],
      'outbounds': [
        {
          'type': 'selector',
          'tag': proxyTag,
          'outbounds': [if (memberTags.length > 1) autoTag, ...memberTags],
          'default': selected.tag,
          // Switching servers should not tear down downloads already in flight.
          'interrupt_exist_connections': false,
        },
        if (memberTags.length > 1)
          {
            'type': 'urltest',
            'tag': autoTag,
            'outbounds': memberTags,
            'url': testUrl,
            'interval': '${testIntervalMinutes}m',
            // Do not flap between servers whose latency differs by noise.
            'tolerance': 50,
            'interrupt_exist_connections': false,
          },
        ...outbounds,
        {'type': 'direct', 'tag': directTag},
      ],
      // Omitted entirely rather than left empty: sing-box rejects an endpoint list
      // that is present and has nothing in it.
      if (endpoints.isNotEmpty || routing.warp != null)
        'endpoints': [
          ...endpoints,
          if (routing.warp case final warp?)
            warp.toEndpoint(
              tag: warpTag,
              detour: routing.warpThroughProxy ? proxyTag : null,
              host: routing.warpEndpoint,
              port: routing.warpPort,
            ),
        ],
      'route': _route(ruleSetPaths, {for (final m in members) m.tag}),
      'experimental': _experimental(),
    };
  }

  /// The proxy members of the config.
  ///
  /// Servers sing-box speaks natively are included verbatim, which is what makes
  /// latency testing and switching without a reconnect possible. A server that needs
  /// Xray appears only when it is the selected one, as the loopback SOCKS entry --
  /// exactly one Xray instance runs at a time, so the others have nothing to point at.
  List<_Member> _proxyMembers(Outbound selected, List<Outbound> servers, LoopbackAuth loopback) {
    final pool = servers.isEmpty ? [selected] : servers;
    final members = <_Member>[
      for (final server in pool)
        if (!server.requiresXray && !server.requiresAmnezia && server.isUsable) _memberOf(server),
    ];
    if (!selected.requiresXray &&
        !selected.requiresAmnezia &&
        !members.any((e) => e.tag == selected.tag)) {
      members.insert(0, _memberOf(selected));
    }
    // One of each other core, whether or not it is the one in use. Both instances run
    // for as long as the tunnel does, which costs a little idle memory and, for the
    // WireGuard-shaped one, its keepalives — and buys the two things that were
    // impossible without it: measuring those servers at all, and switching to one
    // without tearing the tunnel down.
    if (amneziaServerFor(selected, pool) case final server?) {
      members.insert(0, _loopbackMember(server.tag, loopback.amneziaPort, loopback));
    }
    if (xrayServerFor(selected, pool) case final server?) {
      members.insert(0, _loopbackMember(server.tag, loopback.xrayPort, loopback));
    }
    // A server named after one of the generated tags would silently replace it --
    // the selector pointing at itself, or a user's "warp" shadowing the real one.
    final reserved = {proxyTag, autoTag, directTag, warpTag};
    // The server list is kept free of repeated names, but one that slipped through
    // must cost that one entry, not the whole config: sing-box rejects every config
    // that repeats a tag.
    final seen = <String>{};
    return [
      for (final m in members)
        if (!reserved.contains(m.tag) && seen.add(m.tag)) m,
    ];
  }

  /// The one server Xray can carry, or null when there is none it can.
  ///
  /// Exactly one instance runs, so exactly one server can be behind it. The selected
  /// one wins; otherwise the first in the list that Xray can actually be configured
  /// for — a server whose link will not convert is skipped rather than named in the
  /// config with nothing behind it.
  Outbound? xrayServerFor(Outbound selected, List<Outbound> servers) => _pickForCore(
    selected,
    servers,
    (server) => server.requiresXray && XrayConfig.build(server, tricks: tlsTricks) != null,
  );

  /// The one server the AmneziaWG core can carry. See [xrayServerFor].
  Outbound? amneziaServerFor(Outbound selected, List<Outbound> servers) =>
      _pickForCore(selected, servers, (server) => server.requiresAmnezia);

  static Outbound? _pickForCore(
    Outbound selected,
    List<Outbound> servers,
    bool Function(Outbound) carried,
  ) {
    if (selected.isUsable && carried(selected)) return selected;
    for (final server in servers) {
      if (server.isUsable && carried(server)) return server;
    }
    return null;
  }

  /// A server another core is carrying, as sing-box sees it.
  ///
  /// Dialing loopback is safe: with a platform interface sing-box only calls
  /// protect() on outbound sockets and binds to an interface solely when it is not
  /// the default one, so nothing tries to reach 127.0.0.1 via wlan0.
  ///
  /// A destination is handed over as a name when it has one. The other core resolves
  /// it on its own side of the tunnel — Xray with its own resolver, AmneziaWG with
  /// the config's DNS or its fallbacks — which is also what keeps the lookup inside
  /// the tunnel. A dial option here cannot change that: `domain_strategy` and
  /// `domain_resolver` on this outbound only ever applied to dialling 127.0.0.1.
  _Member _loopbackMember(String tag, int port, LoopbackAuth auth) => (
    tag: tag,
    isEndpoint: false,
    json: {
      'type': 'socks',
      'tag': tag,
      'server': '127.0.0.1',
      'server_port': port,
      'version': '5',
      'username': auth.username,
      'password': auth.password,
    },
    // The other core does its own chaining inside its own config.
    chain: const [],
  );

  _Member _memberOf(Outbound server) {
    final json = <String, Object?>{...server.json, 'tag': server.tag};
    // Tags are assigned here rather than stored, because this is the only place the
    // surrounding namespace is known. Each link dials into the next, and the server
    // itself dials into the first.
    final chain = <Map<String, Object?>>[];
    for (var i = 0; i < server.chain.length; i++) {
      final tag = _chainTag(server, i);
      chain.add({...server.chain[i], 'tag': tag});
      if (i == 0) {
        json['detour'] = tag;
      } else {
        chain[i - 1]['detour'] = tag;
      }
    }
    return (tag: server.tag, isEndpoint: server.isEndpoint, json: _decorate(json), chain: chain);
  }

  /// A name for one link of a chain.
  ///
  /// Derived from the server's own tag, which is already unique among servers, and
  /// readable — these show up in the log and in the config screen, and "(shadowtls)"
  /// beside the server it belongs to explains itself where a generated id would not.
  String _chainTag(Outbound server, int index) {
    final type = server.chain[index]['type'] as String? ?? 'chain';
    return '${server.tag} ($type${index == 0 ? '' : '${index + 1}'})';
  }

  /// Everything applied to a server outbound on its way into the config.
  ///
  /// One place rather than two call sites, because the two decorations have to agree
  /// on the same map — applying one to the original and one to a copy is how a
  /// setting ends up silently absent for the selected server only.
  Map<String, Object?> _decorate(Map<String, Object?> outbound) =>
      _withMultiplex(_withInsecure(_withoutDeadDetour(outbound)));

  /// Drops a detour to the bare `direct` outbound.
  ///
  /// sing-box refuses to dial through a direct outbound that carries no options, on
  /// the grounds that it is dialling out written the long way round — and it refuses
  /// lazily, on the first packet, so such a config passes `sing-box check` and then
  /// carries nothing at all.
  ///
  /// This has to happen here rather than only in the parsers. An imported server
  /// keeps its sing-box JSON verbatim in the profile, so a field written before this
  /// was understood survives every update of the app; no amount of fixing what new
  /// imports produce reaches a server that is already saved. This is the one place a
  /// stored server turns into something the core reads, so it is the one place that
  /// repairs all of them, with no migration to write or to get wrong.
  Map<String, Object?> _withoutDeadDetour(Map<String, Object?> outbound) {
    if (outbound['detour'] != directTag) return outbound;
    return {...outbound}..remove('detour');
  }

  /// Adds the `multiplex` block where the protocol has one. See
  /// [MultiplexSettings.appliesTo] for what is excluded and why.
  Map<String, Object?> _withMultiplex(Map<String, Object?> outbound) {
    if (!multiplex.enabled || !MultiplexSettings.appliesTo(outbound)) return outbound;
    return {...outbound, 'multiplex': multiplex.toOption()};
  }

  /// Applies [allowInsecure] to an outbound that has TLS.
  ///
  /// Only where TLS is already configured: adding the field to a plaintext outbound
  /// would be meaningless, and a share link that already asked for it keeps working
  /// with this off.
  Map<String, Object?> _withInsecure(Map<String, Object?> outbound) {
    if (!allowInsecure) return outbound;
    final tls = outbound['tls'];
    if (tls is! Map) return outbound;
    return {
      ...outbound,
      'tls': {...tls.cast<String, Object?>(), 'insecure': true},
    };
  }

  Map<String, Object?> _tunInbound() => {
    'type': 'tun',
    'tag': 'tun-in',
    'address': ['172.19.0.1/30', if (enableIpv6) 'fdfe:dcba:9876::1/126'],
    'mtu': mtu,
    'auto_route': true,
    // With a platform interface sing-box does not act on this itself: it hands it
    // to OpenTun, which decides whether the VpnService grants allowBypass().
    'strict_route': strictRoute,
    // Defaults to gVisor for TCP with the system stack for UDP: the combination SFA
    // ships, and the only one that behaves on the full range of Android kernels. The
    // other two are reachable from settings for the devices where it does not.
    'stack': tunStack,
    // Android takes this from the platform interface and hands it to apps that ask
    // the system for a proxy, so they reach the local one without a TUN round trip.
    if (handsProxyToAndroid)
      'platform': {
        'http_proxy': {'enabled': true, 'server': '127.0.0.1', 'server_port': mixedPort},
      },
    if (perApp.mode == PerAppMode.include && perApp.packages.isNotEmpty)
      'include_package': perApp.packages,
    if (perApp.mode == PerAppMode.exclude && perApp.packages.isNotEmpty)
      'exclude_package': perApp.packages,
  };

  /// Local proxies, for apps and devices that can be pointed at one directly.
  ///
  /// Bound to loopback unless sharing is on. Binding to every interface puts an open
  /// proxy on whatever network the phone is attached to, which on public WIFI is
  /// somebody else's proxy — hence off by default and named for what it does.
  ///
  /// With [localProxyAuth] they demand a login. Without the credentials to demand
  /// they are not opened at all: a proxy meant to be locked must never come up open.
  List<Map<String, Object?>> _localInbounds() {
    if (localProxyAuth && !localProxyLocked) return const [];
    final listen = shareInLocalNetwork ? '0.0.0.0' : '127.0.0.1';
    Map<String, Object?> proxy(String tag, int port) => {
      'type': 'mixed',
      'tag': tag,
      'listen': listen,
      'listen_port': port,
      if (localProxyLocked)
        'users': [
          {'username': localProxyUsername, 'password': localProxyPassword},
        ],
    };
    return [
      if (mixedPort > 0) proxy(mixedInTag, mixedPort),
      if (directPort > 0) proxy(directInTag, directPort),
    ];
  }

  Map<String, Object?> _dns() => {
    'servers': [
      // Resolved through the proxy, so the upstream resolver sees the exit node
      // rather than the user's real network.
      {..._dnsServer(dnsRemoteTag, remoteDns), 'detour': proxyTag},
      // Resolves the proxy server's own hostname, before any tunnel exists. Left
      // empty this is the platform resolver, i.e. whatever DNS the current network
      // handed out — a fixed public resolver would fail wherever it is blocked, and
      // a China-centric default would be wrong for most users.
      if (_usableDirectDns == null)
        {'tag': dnsDirectTag, 'type': 'local'}
      else
        _dnsServer(dnsDirectTag, _usableDirectDns!),
      if (fakeDns)
        {
          'tag': dnsFakeTag,
          'type': 'fakeip',
          'inet4_range': fakeIpV4Range,
          if (enableIpv6) 'inet6_range': fakeIpV6Range,
        },
    ],
    'rules': [
      if (fakeDns)
        {
          // Only for the record types fake addresses can stand in for. Everything
          // else — MX, TXT, and AAAA when the tunnel carries no IPv6 — has to reach
          // a real resolver or the answer is simply wrong.
          'query_type': [if (enableIpv6) 'AAAA', 'A'],
          'server': dnsFakeTag,
        },
    ],
    'final': dnsRemoteTag,
    'strategy': _dnsStrategy,
    // No `independent_cache`: from sing-box 1.14 the cache always keys by server, so
    // an answer fetched through the proxy is never reused to dial the proxy itself.
  };

  /// Auto tracks the IPv6 setting: asking for AAAA records on a tunnel carrying no
  /// IPv6 gets addresses that cannot be reached.
  String get _dnsStrategy =>
      domainStrategy == strategyAuto ? (enableIpv6 ? 'prefer_ipv4' : 'ipv4_only') : domainStrategy;

  /// [directDns], or null to fall back to the platform resolver.
  ///
  /// This resolver has to be given as a literal address. It is the one that resolves
  /// hostnames, so a hostname here has nothing to resolve *it* — sing-box rejects
  /// such a config outright with "missing domain resolver for domain server address",
  /// which surfaces as a tunnel that will not start. Settings refuses to save one, so
  /// reaching this normally is not possible; a restored backup or a hand-edited
  /// profile can still carry one, and degrading to the default beats refusing to
  /// connect at all.
  String? get _usableDirectDns {
    final value = directDns.trim();
    if (value.isEmpty) return null;
    return isIpLiteral(dnsHost(value)) ? value : null;
  }

  /// True for a bare IPv4 or IPv6 address.
  static bool isIpLiteral(String value) =>
      InternetAddress.tryParse(value.replaceAll(RegExp(r'^\[|\]$'), '')) != null;

  /// sing-box 1.12+ takes a bare host in `server` and everything else in fields of its
  /// own, so the address the user wrote has to be taken apart. A bare host means plain
  /// UDP, which is what someone typing `1.1.1.1` means.
  static Map<String, Object?> _dnsServer(String tag, String url) {
    final uri = _dnsUri(url);
    if (uri == null) return {'tag': tag, 'type': 'udp', 'server': url.trim()};
    final scheme = uri.scheme;
    final type = _dnsTypes.contains(scheme) ? scheme : 'udp';
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    return {
      'tag': tag,
      'type': type,
      'server': uri.host,
      // Port 0 is what Dart makes of an empty one ("host:"), and means nothing here.
      if (uri.hasPort && uri.port > 0) 'server_port': uri.port,
      // Left out, sing-box asks at /dns-query. A provider that identifies an account
      // by its path (NextDNS, AdGuard) answers there too, but as nobody in particular.
      if ((type == 'https' || type == 'h3') && path.isNotEmpty && path != '/') 'path': path,
    };
  }

  /// The address as a URI with a scheme, or null when there is no host in it.
  static Uri? _dnsUri(String address) {
    final value = address.trim();
    var rest = value;
    var scheme = 'udp';
    final separator = value.indexOf('://');
    if (separator >= 0) {
      scheme = value.substring(0, separator).toLowerCase();
      rest = value.substring(separator + 3);
    }
    // An IPv6 address with no brackets is one long run of port separators to a URI.
    if (!rest.startsWith('[') && isIpLiteral(rest) && rest.contains(':')) rest = '[$rest]';
    final uri = Uri.tryParse('$scheme://$rest');
    return uri == null || uri.host.isEmpty ? null : uri;
  }

  /// Whether [address] names a resolver this can ask: a host, and a port it could be at.
  static bool isDnsAddress(String address) {
    if (address.contains(' ')) return false;
    final uri = _dnsUri(address);
    return uri != null && (!uri.hasPort || uri.port <= 65535);
  }

  /// The host in a DNS address, however it was written: `1.1.1.1`, `1.1.1.1:53`,
  /// `[2606:4700::1111]:53`, `https://dns.example/query`.
  static String dnsHost(String address) => _dnsUri(address)?.host ?? address.trim();

  /// Transports sing-box accepts. Anything else falls back to UDP rather than being
  /// passed through, because an unknown type stops the tunnel from starting.
  static const _dnsTypes = {'udp', 'tcp', 'tls', 'https', 'quic', 'h3'};

  Map<String, Object?> _route(Map<String, String> ruleSetPaths, Set<String> memberTags) => {
    'rules': [
      // Must come first: every rule below matches on domain, which only exists once
      // the sniffer has read it off the connection.
      if (sniffing) {'action': 'sniff'},
      {'action': 'hijack-dns', 'protocol': 'dns'},
      // Turns a destination hostname into an address before the IP rules below are
      // reached; without it an IP rule set can never match a connection made by name.
      if (resolveDestination) {'action': 'resolve', 'strategy': _dnsStrategy},
      // The direct-port inbound is an escape hatch, so it outranks every rule below
      // — including the quick modes, which is why it comes before them.
      if (directPort > 0)
        {
          'inbound': [directInTag],
          'outbound': directTag,
        },
      // Quick modes short-circuit everything below them. In Rule mode neither
      // matches, so routing proceeds normally.
      {'clash_mode': modeDirect, 'outbound': directTag},
      {'clash_mode': modeGlobal, 'outbound': proxyTag},
      // The user's own rules outrank the presets. Someone who explicitly allows a
      // domain the ad list blocks means it.
      ..._customRules(memberTags),
      // Between the two on purpose: a rule the user wrote still wins, so someone who
      // deliberately blocks one of these keeps that. Anyone who has not said
      // otherwise gets a working app.
      ..._adListFalsePositives(),
      ..._presetRules(ruleSetPaths),
      if (routingMode == RoutingMode.bypassLan) {'ip_is_private': true, 'outbound': directTag},
    ],
    // rule_set lives inside route, not at the top level.
    if (_ruleSetEntries(ruleSetPaths).isNotEmpty) 'rule_set': _ruleSetEntries(ruleSetPaths),
    // Everything that matched no rule. WARP only when an account exists to back it:
    // a final that names a missing outbound is not a degraded config, it is one
    // sing-box refuses outright, leaving the tunnel unable to start.
    'final': routing.warpIsFinal ? warpTag : proxyTag,
    // How the proxy server's own hostname gets resolved. It must go out direct:
    // resolving it through the proxy would require the proxy to already be up.
    // Required from sing-box 1.14; a warning before that.
    'default_domain_resolver': {
      'server': dnsDirectTag,
      if (serverAddressStrategy != strategyAuto) 'strategy': serverAddressStrategy,
    },
    // Lets the core follow the underlying network changing, e.g. WIFI to cellular.
    'auto_detect_interface': true,
  };

  /// User rules, in the order they are listed, which decides between them: the first
  /// that matches wins.
  ///
  /// A run of neighbours that differ only in their value becomes one rule, since the
  /// core compares in order and a hundred single-value rules would be a hundred
  /// comparisons. Only neighbours: collecting a pair from across the list would carry
  /// the later one past whatever stands between them.
  List<Map<String, Object?>> _customRules(Set<String> memberTags) {
    // A record key rather than a joined string: records compare structurally, so
    // the key stays typed all the way to where the value has to be written as a
    // number or a string.
    final runs = <((RuleMatch, RuleAction, String?), List<String>)>[];
    for (final rule in routing.rules) {
      // An invalid rule is skipped rather than emitted. sing-box rejects the whole
      // config over one bad value, so a rule that no longer parses would take the
      // tunnel down instead of simply not matching.
      if (!rule.enabled || !rule.isValid) continue;
      // A rule pointing at WARP with no account registered would name an outbound
      // that does not exist, which sing-box rejects outright — taking the whole
      // tunnel down over one stale rule.
      if (rule.action == RuleAction.warp && !routing.hasWarp) continue;
      // A server that is not in this config falls back to the selector rather than
      // being named: sing-box rejects a route to an outbound it does not have.
      final target = memberTags.contains(rule.server) ? rule.server : null;
      final key = (rule.match, rule.action, target);
      if (runs.isEmpty || runs.last.$1 != key) runs.add((key, []));
      runs.last.$2.add(rule.value.trim());
    }
    return [
      for (final (key, values) in runs)
        {
          key.$1.field: _ruleValues(key.$1, values),
          ...switch (key.$3) {
            final server? => {'outbound': server},
            null => _actionFor(key.$2),
          },
        },
    ];
  }

  /// Values in the shape the field expects: numbers for `port`, lower-cased names
  /// for the fields with a closed set, verbatim otherwise.
  static List<Object> _ruleValues(RuleMatch match, List<String> values) {
    if (match.isNumeric) return [for (final value in values) int.parse(value)];
    if (match.choices != null) return [for (final value in values) value.toLowerCase()];
    return values;
  }

  /// Domains the ad lists block that applications cannot work without.
  ///
  /// `graph.instagram.com` is Instagram's own API, not an ad server. It appears in
  /// SagerNet's list because Instagram serves ads over it too, but blocking it does
  /// not remove the ads -- it stops the app loading at all, as a retry loop with no
  /// explanation anywhere the user can see.
  ///
  /// Deliberately a short, named list rather than a general allowlist feature. Each
  /// entry is here because it was seen breaking something, and carries the cost of
  /// letting that domain's ad traffic through.
  static const adListFalsePositives = ['graph.instagram.com'];

  List<Map<String, Object?>> _adListFalsePositives() {
    // Only worth emitting when something is actually blocking.
    final blocking = routing.activePresets.any((p) => p.action == RuleAction.block);
    if (!blocking) return const [];
    return [
      {'domain': adListFalsePositives, 'outbound': proxyTag},
    ];
  }

  /// Preset rules, blocking ones first so a blocked domain is never sent anywhere.
  List<Map<String, Object?>> _presetRules(Map<String, String> ruleSetPaths) {
    final available = routing.activePresets.where((p) => ruleSetPaths.containsKey(p.id)).toList();
    final blocking = available.where((p) => p.action == RuleAction.block).toList();
    final routed = available.where((p) => p.action != RuleAction.block).toList();

    List<Map<String, Object?>> group(List<RuleSetPreset> presets) {
      final byAction = <RuleAction, List<String>>{};
      for (final preset in presets) {
        byAction.putIfAbsent(preset.action, () => []).add(preset.id);
      }
      return [
        for (final entry in byAction.entries) {'rule_set': entry.value, ..._actionFor(entry.key)},
      ];
    }

    return [...group(blocking), ...group(routed)];
  }

  /// `reject` is an action; the other two are ordinary outbound routes.
  Map<String, Object?> _actionFor(RuleAction action) => switch (action) {
    RuleAction.block => {'action': 'reject'},
    RuleAction.direct => {'outbound': directTag},
    RuleAction.proxy => {'outbound': proxyTag},
    RuleAction.warp => {'outbound': warpTag},
  };

  /// Local files only. Remote rule sets would make an unreachable GitHub fatal to
  /// starting the tunnel, so they are downloaded ahead of time instead.
  List<Map<String, Object?>> _ruleSetEntries(Map<String, String> ruleSetPaths) => [
    for (final preset in routing.activePresets)
      if (ruleSetPaths[preset.id] case final path?)
        {'type': 'local', 'tag': preset.id, 'format': 'binary', 'path': path},
  ];

  Map<String, Object?> _experimental() => {
    // clash_api creates the traffic manager the status stream reads. Leaving
    // external_controller unset means it does that WITHOUT opening a control port,
    // which on Android any other app could reach — so the port stays closed unless
    // the user asks for one, and carries a secret when they do.
    'clash_api': <String, Object?>{
      'default_mode': modeRule,
      if (clashApiPort > 0) ...{
        // Loopback only, whatever the sharing setting says. This API can switch
        // outbounds and read every connection; putting it on the local network is
        // not a knob worth offering.
        'external_controller': '127.0.0.1:$clashApiPort',
        'secret': clashApiSecret,
      },
    },
    'cache_file': {'enabled': true, 'store_fakeip': fakeDns},
  };
}
