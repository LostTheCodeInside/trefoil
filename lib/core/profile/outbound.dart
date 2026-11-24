import 'server_check.dart';

/// A single proxy server, stored in the shape sing-box wants to receive it.
///
/// The parsers deliberately produce sing-box outbound JSON directly rather than an
/// intermediate model of our own. Share links are a sprawling, semi-documented family of
/// formats and every extra representation between the link and the core is another
/// place for a field to get silently dropped.
class Outbound {
  const Outbound({
    required this.tag,
    required this.type,
    required this.json,
    this.subscriptionId,
    this.unsupported = const [],
    this.link,
    this.requiresXray = false,
    this.chain = const [],
    this.amneziaConf,
  });

  /// Display name, and the sing-box outbound tag. Unique within a config.
  final String tag;

  /// sing-box outbound type: vmess, vless, trojan, shadowsocks, hysteria2, tuic…
  final String type;

  /// The full outbound object, ready to be dropped into `outbounds[]`.
  final Map<String, Object?> json;

  /// Which subscription this came from, or null when added manually.
  final String? subscriptionId;

  /// Features the share link asked for that the bundled core cannot provide.
  ///
  /// Silently dropping these is how a config ends up looking valid and failing with
  /// an opaque handshake error, so they are carried through to the UI instead.
  final List<String> unsupported;

  bool get isUsable => problem == null;

  /// What stands in the way of using this server, or null.
  ///
  /// Worked out from the server rather than stored with it, so one saved by a version
  /// that did not look is caught as well. A server another core carries is never in
  /// sing-box's config as itself, and only its address is held to anything.
  ServerProblem? get problem => (_problems[this] ??= [_findProblem()]).single;

  ServerProblem? _findProblem() {
    if (unsupported.isNotEmpty) return ServerProblem.parse(unsupported.first);
    if (requiresAmnezia) return null;
    if (requiresXray) {
      return serverPort > 0 && serverPort <= 65535
          ? null
          : ServerProblem(ServerProblem.port, '$serverPort');
    }
    return ServerCheck.of(json, chain: chain);
  }

  /// Kept per server: a list of thousands asks again on every frame it is drawn. A
  /// list of one, since the answer is itself often null.
  static final _problems = Expando<List<ServerProblem?>>();

  /// The share link this came from, kept verbatim.
  ///
  /// Kept for every scheme, not only the ones a second core has to re-read. It is
  /// also the only way a server can leave this app again — see [ServerExport] —
  /// and a server whose link was thrown away can never be handed to anything else.
  ///
  /// Xray's config schema is not a reshuffle of sing-box's — protocols, transports
  /// and TLS all sit in different places with different names. Rebuilding an Xray
  /// outbound from the sing-box one would mean a lossy translation in both
  /// directions, so the original link is retained and re-parsed for whichever core
  /// ends up running the server.
  final String? link;

  /// True when only Xray-core can run this server.
  ///
  /// Post-quantum REALITY, VLESS encryption and XHTTP: sing-box has no field for any of
  /// them even in v1.14, so such a server is handed to Xray, which runs behind a
  /// loopback SOCKS inbound that sing-box dials as its proxy.
  final bool requiresXray;

  /// The AmneziaWG configuration this server needs, when it has one.
  ///
  /// AmneziaWG is WireGuard with the handshake reshaped, and none of that reshaping
  /// is a field sing-box has. So such a server is not an endpoint at all: a third
  /// core raises it and offers a loopback SOCKS port, and sing-box dials that as an
  /// ordinary proxy — the same arrangement Xray already has here.
  ///
  /// Kept as the config file text rather than translated, because the library takes
  /// exactly that and translating it twice is one more place for a parameter to be
  /// dropped. A dropped parameter is a handshake the server rejects without saying
  /// why.
  final String? amneziaConf;

  bool get requiresAmnezia => amneziaConf != null;

  /// Whether opening a TCP connection to this server's address means anything.
  ///
  /// False for the protocols carried over UDP: nothing is listening on that port for
  /// a TCP handshake, so a probe there measures the absence of a service rather than
  /// the distance to one. Those servers can only be measured through a running core.
  bool get reachableOverTcp => !const {'wireguard', 'hysteria', 'hysteria2', 'tuic'}.contains(type);

  /// What to call this protocol on screen.
  ///
  /// [type] is the sing-box outbound type, and for an AmneziaWG server that is a lie
  /// twice over: sing-box sees a SOCKS proxy, and the config it came from is not
  /// WireGuard. Someone holding both kinds needs to be able to tell them apart in a
  /// list, and the tag is theirs to choose rather than something to read a protocol
  /// out of.
  String get displayType => requiresAmnezia ? 'amneziawg' : type;

  /// Outbounds this one dials through, outermost first.
  ///
  /// A few protocols are not one outbound but two. ShadowTLS carries a Shadowsocks
  /// connection inside a TLS handshake that looks like an ordinary visit to a real
  /// website, and sing-box expresses that as a `shadowtls` outbound with the
  /// Shadowsocks one detouring into it — while Clash expresses the same thing as a
  /// plugin on a single proxy.
  ///
  /// Stored without tags. Tags and the `detour` that links them are assigned when the
  /// config is built, which is the only place the surrounding namespace is known; a
  /// tag written in here would have to be rewritten every time the server was renamed
  /// to keep a name no other server had.
  ///
  /// These are not exits in their own right: nothing routes to them, and they never
  /// appear in the selector or the latency test.
  final List<Map<String, Object?>> chain;

  /// Whether this belongs in `endpoints[]` rather than `outbounds[]`.
  ///
  /// WireGuard stopped being an outbound in sing-box 1.11. It still shares the tag
  /// namespace, so such a server joins the selector and the latency tests like any
  /// other — it simply has to be written into a different array, and putting it in
  /// the wrong one is a config the core refuses outright.
  bool get isEndpoint => type == 'wireguard' && !requiresAmnezia;

  String get server {
    if (json['server'] case final String value when value.isNotEmpty) return value;
    if (json['peers'] case [final Map peer, ...]) return peer['address'] as String? ?? '';
    // A chained outbound carries the address on the link that actually dials out.
    if (chain case [final Map first, ...]) return first['server'] as String? ?? '';
    return '';
  }

  int get serverPort {
    final port = (json['server_port'] as num?)?.toInt();
    if (port != null) return port;
    if (chain case [final Map first, ...]) {
      if ((first['server_port'] as num?)?.toInt() case final value?) return value;
    }
    // An endpoint keeps its address on the peer instead.
    if (json['peers'] case [final Map peer, ...]) {
      return (peer['port'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  Outbound withTag(String newTag) => copyWith(tag: newTag);

  /// The list with every repeated tag renamed: "X", "X (2)", "X (3)".
  ///
  /// Tags become sing-box outbound tags, and a single repeat makes the core reject
  /// the whole config, so no list of servers may hold one. The same server arrives
  /// twice easily: one subscription imported twice, or a server added by hand that a
  /// subscription also lists. Earlier entries keep their names and a new name is
  /// never one another entry already has, so the selected server and the rules that
  /// point at servers stay where they were.
  static List<Outbound> withUniqueTags(List<Outbound> servers) {
    final names = {for (final server in servers) server.tag};
    if (names.length == servers.length) return servers;
    final seen = <String>{};
    return [
      for (final server in servers)
        if (seen.add(server.tag)) server else server.withTag(_freeName(server.tag, names, seen)),
    ];
  }

  /// The first "name (n)" no entry has and none has been given, recorded as taken.
  static String _freeName(String name, Set<String> names, Set<String> seen) {
    var suffix = 2;
    while (names.contains('$name ($suffix)') || seen.contains('$name ($suffix)')) {
      suffix++;
    }
    final free = '$name ($suffix)';
    seen.add(free);
    return free;
  }

  /// The same server, remembering the link it was written as.
  ///
  /// Returns `this` when it already has one, so a parser that captured its own does
  /// not get a needless copy.
  Outbound withLink(String value) => link == value ? this : copyWith(link: value);

  /// The same server with the given fields replaced and every other one carried over.
  ///
  /// The one place a server is copied. Copies written out field by field each had to
  /// remember every field, and the subscription parser's did not: AmneziaWG servers
  /// arrived without their config and ShadowTLS ones without their chain — listed,
  /// selectable, and unable to connect.
  Outbound copyWith({String? tag, String? subscriptionId, String? link}) => Outbound(
    tag: tag ?? this.tag,
    type: type,
    json: tag == null ? json : {...json, 'tag': tag},
    subscriptionId: subscriptionId ?? this.subscriptionId,
    unsupported: unsupported,
    link: link ?? this.link,
    requiresXray: requiresXray,
    chain: chain,
    amneziaConf: amneziaConf,
  );

  Map<String, Object?> toStorage() => {
    'tag': tag,
    'type': type,
    'json': json,
    'subscriptionId': subscriptionId,
    'unsupported': unsupported,
    'link': link,
    'requiresXray': requiresXray,
    if (chain.isNotEmpty) 'chain': chain,
    'amneziaConf': ?amneziaConf,
  };

  factory Outbound.fromStorage(Map<String, Object?> map) => Outbound(
    tag: map['tag'] as String? ?? '',
    type: map['type'] as String? ?? '',
    json: (map['json'] as Map).cast<String, Object?>(),
    subscriptionId: map['subscriptionId'] as String?,
    // Absent in profiles saved before this field existed.
    unsupported: (map['unsupported'] as List?)?.cast<String>() ?? const [],
    link: map['link'] as String?,
    requiresXray: map['requiresXray'] as bool? ?? false,
    // Absent in profiles saved before chained outbounds existed.
    chain: [
      for (final link in (map['chain'] as List?) ?? const []) (link as Map).cast<String, Object?>(),
    ],
    amneziaConf: map['amneziaConf'] as String?,
  );
}
