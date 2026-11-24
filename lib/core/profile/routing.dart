import 'warp.dart';

/// Where a matched connection goes.
enum RuleAction {
  proxy,
  direct,
  block,

  /// Out through Cloudflare WARP. Only selectable once an account is registered.
  warp;

  static RuleAction parse(Object? raw) => switch (raw) {
    'direct' => RuleAction.direct,
    'block' => RuleAction.block,
    'warp' => RuleAction.warp,
    _ => RuleAction.proxy,
  };
}

/// What a rule matches on. These map one-to-one onto sing-box rule fields.
enum RuleMatch {
  domainSuffix,
  domain,
  domainKeyword,
  domainRegex,
  ipCidr,
  packageName,
  port,
  portRange,
  network,
  protocol;

  /// The sing-box route-rule key this becomes.
  String get field => switch (this) {
    RuleMatch.domainSuffix => 'domain_suffix',
    RuleMatch.domain => 'domain',
    RuleMatch.domainKeyword => 'domain_keyword',
    RuleMatch.domainRegex => 'domain_regex',
    RuleMatch.ipCidr => 'ip_cidr',
    RuleMatch.packageName => 'package_name',
    RuleMatch.port => 'port',
    RuleMatch.portRange => 'port_range',
    RuleMatch.network => 'network',
    RuleMatch.protocol => 'protocol',
  };

  /// sing-box types `port` as a list of numbers and everything else here as a list
  /// of strings. A quoted port number is rejected, so the distinction has to
  /// survive all the way into the generated config.
  bool get isNumeric => this == RuleMatch.port;

  /// The closed set of values this field accepts, or null when it is free text.
  ///
  /// Offering a picker instead of a text box is what stops a typo becoming a rule
  /// that silently never matches — `protocol: htp` is valid JSON and matches
  /// nothing, and nothing about the result says why.
  List<String>? get choices => switch (this) {
    RuleMatch.network => networks,
    RuleMatch.protocol => sniffedProtocols,
    _ => null,
  };

  /// Only matched once traffic has been sniffed, which the sniffer must be on to do.
  bool get needsSniffing => this == RuleMatch.protocol;

  static const networks = ['tcp', 'udp'];

  /// Exactly what sing-box's sniffers report, taken from its own constants. A name
  /// outside this list would parse and then never match.
  static const sniffedProtocols = [
    'http',
    'tls',
    'quic',
    'dns',
    'stun',
    'bittorrent',
    'dtls',
    'ssh',
    'rdp',
    'ntp',
  ];

  /// Whether [value] produces a rule the core will accept.
  ///
  /// Checked here rather than only in the UI because a rule also arrives from a
  /// restored backup, where nobody is around to see a validation message.
  bool isValid(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (choices case final allowed?) return allowed.contains(trimmed.toLowerCase());
    return switch (this) {
      RuleMatch.port => _isPort(trimmed),
      RuleMatch.portRange => _isPortRange(trimmed),
      RuleMatch.domainRegex => _isRegex(trimmed),
      _ => true,
    };
  }

  static bool _isPort(String value) {
    final port = int.tryParse(value);
    return port != null && port >= 1 && port <= 65535;
  }

  /// sing-box writes a range as `start:end`, with either side allowed to be empty
  /// for an open end — `:1000` is "up to 1000", `1000:` is "1000 and above".
  static bool _isPortRange(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return false;
    if (parts[0].isEmpty && parts[1].isEmpty) return false;
    for (final part in parts) {
      if (part.isNotEmpty && !_isPort(part)) return false;
    }
    if (parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return int.parse(parts[0]) <= int.parse(parts[1]);
    }
    return true;
  }

  static bool _isRegex(String value) {
    try {
      RegExp(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  static RuleMatch parse(Object? raw) =>
      RuleMatch.values.firstWhere((e) => e.name == raw, orElse: () => RuleMatch.domainSuffix);
}

/// One user-written routing rule.
class RoutingRule {
  const RoutingRule({
    required this.match,
    required this.value,
    required this.action,
    this.enabled = true,
    String? server,
  }) : server = action == RuleAction.proxy ? server : null;

  final RuleMatch match;
  final String value;
  final RuleAction action;
  final bool enabled;

  /// For [RuleAction.proxy]: the server this rule's traffic goes through, by tag.
  /// Null means whichever server is selected.
  ///
  /// A server that has since gone, or that cannot be in the config right now (the
  /// other cores carry one server each), falls back to the selected one instead of
  /// naming an outbound that does not exist and stopping the tunnel.
  final String? server;

  RoutingRule copyWith({RuleMatch? match, String? value, RuleAction? action, bool? enabled}) =>
      RoutingRule(
        match: match ?? this.match,
        value: value ?? this.value,
        action: action ?? this.action,
        enabled: enabled ?? this.enabled,
        server: server,
      );

  /// Whether this rule can be emitted at all. An invalid one is skipped when the
  /// config is built rather than dropped from storage, so a rule that stopped being
  /// valid across a version can still be seen and corrected.
  bool get isValid => match.isValid(value);

  Map<String, Object?> toJson() => {
    'match': match.name,
    'value': value,
    'action': action.name,
    'enabled': enabled,
    'server': ?server,
  };

  factory RoutingRule.fromJson(Map<String, Object?> map) => RoutingRule(
    match: RuleMatch.parse(map['match']),
    value: map['value'] as String? ?? '',
    action: RuleAction.parse(map['action']),
    enabled: map['enabled'] as bool? ?? true,
    server: map['server'] as String?,
  );
}

/// Where the rule sets are fetched from.
///
/// Every option serves the same files in the same layout; they differ only in who
/// is between the device and them.
abstract final class RuleSetSource {
  /// SagerNet's own repositories, on raw.githubusercontent.com.
  static const official = 'official';

  /// A CDN that mirrors GitHub, reachable on some networks where GitHub is not.
  static const jsdelivr = 'jsdelivr';

  /// A base address the user supplies, laid out like the official one.
  static const custom = 'custom';

  static const values = [official, jsdelivr, custom];
}

/// Where a preset's `.srs` file is published.
///
/// Presets default to SagerNet's own repositories, whose layout is derived from the
/// preset id. This exists for the ones that are not there — a bigger blocklist than
/// SagerNet publishes has to come from somewhere else, and pretending otherwise
/// would mean a preset that silently never downloads.
///
/// Only the *matching* criteria come out of the file. The action a matched
/// connection gets is [RuleSetPreset.action], which lives in this catalogue and
/// never in the download — so a wrong or hostile file can over-block or under-block,
/// and can never send traffic somewhere it was not already going.
class RuleSetOrigin {
  const RuleSetOrigin({
    required this.owner,
    required this.repository,
    required this.branch,
    required this.file,
  });

  final String owner;
  final String repository;
  final String branch;

  /// The name upstream uses, which need not match the id we give it.
  final String file;

  /// Loyalsoldier's merge of AdGuard, EasyList, EasyPrivacy and Peter Lowe's list,
  /// ported to sing-box's binary format and rebuilt daily.
  ///
  /// Around 187,000 domains against SagerNet's 890, and complementary rather than a
  /// superset — SagerNet's carries Russian and Chinese entries this one does not, so
  /// both switches are worth having on.
  static const loyalsoldierAds = RuleSetOrigin(
    owner: 'lyc8503',
    repository: 'sing-box-rules',
    branch: 'rule-set-geosite',
    file: 'geosite-category-ads-all.srs',
  );
}

/// A downloadable list of domains or networks, applied as one switch.
class RuleSetPreset {
  const RuleSetPreset({
    required this.id,
    required this.label,
    required this.description,
    required this.action,
    required this.isIpSet,
    this.defaultOn = false,
    this.origin,
  });

  final String id;
  final String label;
  final String description;
  final RuleAction action;

  /// Null for the ones SagerNet publishes, which is nearly all of them.
  final RuleSetOrigin? origin;

  /// Which of SagerNet's two repositories holds it. IP sets and domain sets are
  /// published separately, and the id says which is which.
  String get repository =>
      origin?.repository ?? (id.startsWith('geoip') ? 'sing-geoip' : 'sing-geosite');

  String get _owner => origin?.owner ?? 'SagerNet';

  String get _branch => origin?.branch ?? 'rule-set';

  /// The remote name, which is not always our id: two catalogue entries can point at
  /// files upstream happens to call the same thing.
  String get fileName => origin?.file ?? '$id.srs';

  /// Where to fetch it from.
  ///
  /// The address is derived rather than pinned because the one place these are
  /// published is raw.githubusercontent.com, which is blocked on a good number of
  /// the networks this app exists for — and a routing list that cannot be downloaded
  /// is a routing rule that silently does not apply. [source] picks a mirror of the
  /// same layout; [base] is used only by [RuleSetSource.custom].
  String urlFor(String source, String base) => switch (source) {
    RuleSetSource.jsdelivr => 'https://cdn.jsdelivr.net/gh/$_owner/$repository@$_branch/$fileName',
    // A user's mirror mirrors SagerNet. Asking it for a file published elsewhere
    // would 404, so a third-party preset falls through to its own address instead —
    // and shows as unavailable if that is what turns out to be unreachable.
    RuleSetSource.custom when base.trim().isNotEmpty && origin == null =>
      '${_withoutTrailingSlash(base)}/$repository/$_branch/$fileName',
    _ => 'https://raw.githubusercontent.com/$_owner/$repository/$_branch/$fileName',
  };

  static String _withoutTrailingSlash(String value) {
    var trimmed = value.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  /// IP-based sets can only be matched after the destination address is known,
  /// which is why they are kept separate from domain sets when rules are built.
  final bool isIpSet;
  final bool defaultOn;

  /// Every entry here was checked to exist; a 404 would leave the tunnel unable to
  /// start, because sing-box treats a missing rule set as a fatal config error.
  ///
  /// The country bundles send a country's own traffic straight out instead of
  /// through the proxy. Each is a pair — domains and addresses — because a site is
  /// reached by name and its CDN by address. Only sets that exist upstream are
  /// listed: there is no geosite for Indonesia, so that one is IP-only.
  static const catalog = <RuleSetPreset>[
    RuleSetPreset(
      id: 'geosite-category-ads-all',
      label: 'Block ads & trackers',
      description: 'Drops requests to known advertising and tracking domains',
      action: RuleAction.block,
      isIpSet: false,
      defaultOn: true,
    ),
    RuleSetPreset(
      id: 'geosite-ads-extended',
      label: 'Block ads & trackers — large list',
      description: 'About 187,000 domains from AdGuard and EasyList, rebuilt daily',
      action: RuleAction.block,
      isIpSet: false,
      origin: RuleSetOrigin.loyalsoldierAds,
    ),
    RuleSetPreset(
      id: 'geoip-id',
      label: 'Indonesian IPs go direct',
      description: 'Local services skip the proxy, so they stay fast',
      action: RuleAction.direct,
      isIpSet: true,
      defaultOn: true,
    ),
    RuleSetPreset(
      id: 'geosite-private',
      label: 'Local domains go direct',
      description: 'Intranet and .local names resolve on your own network',
      action: RuleAction.direct,
      isIpSet: false,
      defaultOn: true,
    ),
    RuleSetPreset(
      id: 'geosite-cn',
      label: 'Chinese sites go direct',
      description: 'Skip the proxy for mainland Chinese domains',
      action: RuleAction.direct,
      isIpSet: false,
    ),
    RuleSetPreset(
      id: 'geoip-cn',
      label: 'Chinese IPs go direct',
      description: 'Pairs with the Chinese sites list',
      action: RuleAction.direct,
      isIpSet: true,
    ),
    RuleSetPreset(
      id: 'geosite-category-ir',
      label: 'Iranian sites go direct',
      description: 'Skip the proxy for Iranian domains',
      action: RuleAction.direct,
      isIpSet: false,
    ),
    RuleSetPreset(
      id: 'geoip-ir',
      label: 'Iranian IPs go direct',
      description: 'Pairs with the Iranian sites list',
      action: RuleAction.direct,
      isIpSet: true,
    ),
    RuleSetPreset(
      id: 'geosite-category-ru',
      label: 'Russian sites go direct',
      description: 'Skip the proxy for Russian domains',
      action: RuleAction.direct,
      isIpSet: false,
    ),
    RuleSetPreset(
      id: 'geoip-ru',
      label: 'Russian IPs go direct',
      description: 'Pairs with the Russian sites list',
      action: RuleAction.direct,
      isIpSet: true,
    ),
    RuleSetPreset(
      id: 'geosite-category-porn',
      label: 'Block adult sites',
      description: 'Off by default',
      action: RuleAction.block,
      isIpSet: false,
    ),
  ];

  static RuleSetPreset? byId(String id) {
    for (final preset in catalog) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}

/// The user's complete routing configuration.
class RoutingSettings {
  const RoutingSettings({
    this.rules = const [],
    this.enabledPresets = const {},
    this.warp,
    this.warpThroughProxy = true,
    this.warpForAll = false,
    this.warpEndpoint = '',
    this.warpPort = 0,
    this.ruleSetSource = RuleSetSource.official,
    this.ruleSetBase = '',
  });

  final List<RoutingRule> rules;
  final Set<String> enabledPresets;

  /// The registered WARP account, or null when the feature is off.
  final WarpAccount? warp;

  /// Whether WARP dials through the proxy (a second hop, which is the point when a
  /// site blocks the proxy's exit IP) or straight out (an exit of its own).
  final bool warpThroughProxy;

  /// Whether everything that matches no rule leaves through WARP instead of the
  /// proxy.
  ///
  /// Off, WARP is only a rule target: traffic reaches it because a rule said so, and
  /// the exit IP for everything else stays the proxy server's. On, WARP becomes the
  /// exit and the proxy becomes the transport underneath it — which is what someone
  /// wants when a site blocks their VPS address.
  ///
  /// Meaningless without a registered account, and [RoutingSettings.warpIsFinal]
  /// rather than this field is what the config builder must ask: naming an outbound
  /// that is not in the config makes sing-box refuse to start at all.
  final bool warpForAll;

  /// Override for the WARP endpoint address, or empty to use the one registration
  /// handed back. Cloudflare answers on many addresses and which ones a given
  /// network leaves alone varies.
  final String warpEndpoint;

  /// Override for the WARP endpoint port, or 0 for the registered one.
  final int warpPort;

  /// Where rule sets are downloaded from; see [RuleSetSource].
  final String ruleSetSource;

  /// Base address for [RuleSetSource.custom].
  final String ruleSetBase;

  bool get hasWarp => warp != null;

  /// Whether the generated config should route everything through WARP.
  ///
  /// The account check is the point of this getter. A stored preference outlives the
  /// account it was set for — turning WARP off leaves it true — and acting on it then
  /// would produce a config naming an endpoint that does not exist.
  bool get warpIsFinal => warpForAll && hasWarp;

  static RoutingSettings get defaults => RoutingSettings(
    enabledPresets: {
      for (final preset in RuleSetPreset.catalog)
        if (preset.defaultOn) preset.id,
    },
  );

  List<RuleSetPreset> get activePresets =>
      RuleSetPreset.catalog.where((p) => enabledPresets.contains(p.id)).toList();

  /// [clearWarp] is separate because null means "leave it alone" everywhere else.
  RoutingSettings copyWith({
    List<RoutingRule>? rules,
    Set<String>? enabledPresets,
    WarpAccount? warp,
    bool? warpThroughProxy,
    bool? warpForAll,
    String? warpEndpoint,
    int? warpPort,
    String? ruleSetSource,
    String? ruleSetBase,
    bool clearWarp = false,
  }) => RoutingSettings(
    rules: rules ?? this.rules,
    enabledPresets: enabledPresets ?? this.enabledPresets,
    warp: clearWarp ? null : (warp ?? this.warp),
    warpThroughProxy: warpThroughProxy ?? this.warpThroughProxy,
    warpForAll: warpForAll ?? this.warpForAll,
    warpEndpoint: warpEndpoint ?? this.warpEndpoint,
    warpPort: warpPort ?? this.warpPort,
    ruleSetSource: ruleSetSource ?? this.ruleSetSource,
    ruleSetBase: ruleSetBase ?? this.ruleSetBase,
  );

  Map<String, Object?> toJson() => {
    'rules': rules.map((e) => e.toJson()).toList(),
    'enabledPresets': enabledPresets.toList(),
    'warp': warp?.toJson(),
    'warpThroughProxy': warpThroughProxy,
    'warpForAll': warpForAll,
    'warpEndpoint': warpEndpoint,
    'warpPort': warpPort,
    'ruleSetSource': ruleSetSource,
    'ruleSetBase': ruleSetBase,
  };

  factory RoutingSettings.fromJson(Map<String, Object?> map) => RoutingSettings(
    rules: (map['rules'] as List? ?? [])
        .map((e) => RoutingRule.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
    enabledPresets: (map['enabledPresets'] as List? ?? []).cast<String>().toSet(),
    warp: map['warp'] == null
        ? null
        : WarpAccount.fromJson((map['warp'] as Map).cast<String, Object?>()),
    warpThroughProxy: map['warpThroughProxy'] as bool? ?? true,
    // Absent in profiles written before this existed, which must read back as off.
    warpForAll: map['warpForAll'] as bool? ?? false,
    warpEndpoint: map['warpEndpoint'] as String? ?? '',
    warpPort: (map['warpPort'] as num?)?.toInt() ?? 0,
    ruleSetSource: map['ruleSetSource'] as String? ?? RuleSetSource.official,
    ruleSetBase: map['ruleSetBase'] as String? ?? '',
  );
}
