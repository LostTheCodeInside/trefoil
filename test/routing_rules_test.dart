import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/warp.dart';

/// The rule fields here map onto sing-box v1.13.19's `option/rule.go`: `port` is a
/// list of numbers, `port_range` a list of `start:end` strings, and `network` and
/// `protocol` closed sets. A value in the wrong shape is rejected by the core for
/// the whole config, not just the rule, which is why the typing is tested rather
/// than assumed.
void main() {
  _warpAsFinal();
  _falsePositives();
  _presetOrigins();
  _protocolRules();
  List<Map<String, Object?>> rulesFor(List<RoutingRule> rules) {
    final server = ShareLink.parse('trojan://pw@a.example:443#A')!;
    final config = ConfigBuilder(routing: RoutingSettings(rules: rules))
        .buildMap(server, servers: [server]);
    final route = (config['route'] as Map)['rules'] as List;
    // Everything before the user's rules is generated plumbing.
    return route.cast<Map<String, Object?>>().where((rule) {
      return rule.keys.any(
        (key) => const {
          'domain',
          'domain_suffix',
          'domain_keyword',
          'domain_regex',
          'ip_cidr',
          'package_name',
          'port',
          'port_range',
          'network',
        }.contains(key),
      );
    }).toList();
  }

  group('value typing', () {
    test('ports are numbers, and repeats collapse into one rule', () {
      final rules = rulesFor(const [
        RoutingRule(match: RuleMatch.port, value: '25', action: RuleAction.block),
        RoutingRule(match: RuleMatch.port, value: '465', action: RuleAction.block),
      ]);
      expect(rules.single['port'], [25, 465]);
      expect(rules.single['action'], 'reject');
    });

    test('port ranges stay strings', () {
      final rules = rulesFor(const [
        RoutingRule(match: RuleMatch.portRange, value: '8000:8999', action: RuleAction.direct),
      ]);
      expect(rules.single['port_range'], ['8000:8999']);
    });

    test('closed sets are lower-cased on the way out', () {
      final rules = rulesFor(const [
        RoutingRule(match: RuleMatch.network, value: 'UDP', action: RuleAction.direct),
      ]);
      expect(rules.single['network'], ['udp']);
    });

    test('a regex is carried through verbatim', () {
      final rules = rulesFor(const [
        RoutingRule(match: RuleMatch.domainRegex, value: r'^ads\..*$', action: RuleAction.block),
      ]);
      expect(rules.single['domain_regex'], [r'^ads\..*$']);
    });

    test('rules with different actions do not merge', () {
      final rules = rulesFor(const [
        RoutingRule(match: RuleMatch.port, value: '25', action: RuleAction.block),
        RoutingRule(match: RuleMatch.port, value: '80', action: RuleAction.direct),
      ]);
      expect(rules.length, 2);
      expect(rules.firstWhere((e) => e['action'] == 'reject')['port'], [25]);
      expect(rules.firstWhere((e) => e['outbound'] == 'direct')['port'], [80]);
    });
  });

  group('invalid rules are skipped, not emitted', () {
    test('a port outside the range would otherwise fail the whole config', () {
      expect(
        rulesFor(const [
          RoutingRule(match: RuleMatch.port, value: '99999', action: RuleAction.block),
        ]),
        isEmpty,
      );
      expect(
        rulesFor(const [
          RoutingRule(match: RuleMatch.port, value: 'http', action: RuleAction.block),
        ]),
        isEmpty,
      );
    });

    test('a value outside a closed set', () {
      expect(
        rulesFor(const [
          RoutingRule(match: RuleMatch.network, value: 'sctp', action: RuleAction.direct),
        ]),
        isEmpty,
      );
    });

    test('a regex that does not compile', () {
      expect(
        rulesFor(const [
          RoutingRule(match: RuleMatch.domainRegex, value: '(unclosed', action: RuleAction.block),
        ]),
        isEmpty,
      );
    });

    test('the valid ones around it still apply', () {
      final rules = rulesFor(const [
        RoutingRule(match: RuleMatch.port, value: '99999', action: RuleAction.block),
        RoutingRule(match: RuleMatch.port, value: '25', action: RuleAction.block),
      ]);
      expect(rules.single['port'], [25]);
    });
  });

  group('RuleMatch.isValid', () {
    test('ports', () {
      expect(RuleMatch.port.isValid('1'), isTrue);
      expect(RuleMatch.port.isValid('65535'), isTrue);
      expect(RuleMatch.port.isValid('0'), isFalse);
      expect(RuleMatch.port.isValid('65536'), isFalse);
      expect(RuleMatch.port.isValid(''), isFalse);
    });

    test('port ranges, including the open-ended forms', () {
      expect(RuleMatch.portRange.isValid('1000:2000'), isTrue);
      expect(RuleMatch.portRange.isValid(':1000'), isTrue);
      expect(RuleMatch.portRange.isValid('1000:'), isTrue);
      expect(RuleMatch.portRange.isValid(':'), isFalse);
      expect(RuleMatch.portRange.isValid('2000:1000'), isFalse, reason: 'end before start');
      expect(RuleMatch.portRange.isValid('1000'), isFalse, reason: 'not a range');
      expect(RuleMatch.portRange.isValid('1000:2000:3000'), isFalse);
    });

    test('closed sets accept only their own members, in any case', () {
      expect(RuleMatch.network.isValid('tcp'), isTrue);
      expect(RuleMatch.network.isValid('UDP'), isTrue);
      expect(RuleMatch.network.isValid('icmp'), isFalse);
      expect(RuleMatch.protocol.isValid('bittorrent'), isTrue);
      expect(RuleMatch.protocol.isValid('htp'), isFalse);
    });

    test('free-text fields take anything that is not empty', () {
      expect(RuleMatch.domainSuffix.isValid('example.com'), isTrue);
      expect(RuleMatch.domainSuffix.isValid('  '), isFalse);
    });
  });

  group('editing', () {
    test('copyWith changes one field and leaves the rest', () {
      const rule = RoutingRule(
        match: RuleMatch.domainSuffix,
        value: 'example.com',
        action: RuleAction.proxy,
        enabled: false,
      );
      final edited = rule.copyWith(value: 'other.com');
      expect(edited.value, 'other.com');
      expect(edited.match, RuleMatch.domainSuffix);
      expect(edited.action, RuleAction.proxy);
      expect(edited.enabled, isFalse);
    });

    test('a stored rule survives a round-trip through JSON', () {
      const rule = RoutingRule(
        match: RuleMatch.portRange,
        value: '8000:8999',
        action: RuleAction.direct,
      );
      final restored = RoutingRule.fromJson(rule.toJson());
      expect(restored.match, RuleMatch.portRange);
      expect(restored.value, '8000:8999');
      expect(restored.action, RuleAction.direct);
    });

    test('a match name this version does not know falls back rather than throwing', () {
      final restored = RoutingRule.fromJson(const {
        'match': 'somethingNew',
        'value': 'x',
        'action': 'direct',
      });
      expect(restored.match, RuleMatch.domainSuffix);
    });
  });
}

/// Protocol rules are kept apart from the rest because the generated config also
/// carries a `protocol` key on its DNS hijack rule, which is a bare string rather
/// than a list — telling them apart is the point.
void _protocolRules() {
  group('protocol rules', () {
    List<Map<String, Object?>> protocolRulesFor(List<RoutingRule> rules) {
      final server = ShareLink.parse('trojan://pw@a.example:443#A')!;
      final config = ConfigBuilder(routing: RoutingSettings(rules: rules))
          .buildMap(server, servers: [server]);
      return ((config['route'] as Map)['rules'] as List)
          .cast<Map<String, Object?>>()
          .where((rule) => rule['protocol'] is List)
          .toList();
    }

    test('are emitted as a list, alongside the DNS hijack that is not', () {
      final rules = protocolRulesFor(const [
        RoutingRule(match: RuleMatch.protocol, value: 'bittorrent', action: RuleAction.block),
        RoutingRule(match: RuleMatch.protocol, value: 'quic', action: RuleAction.direct),
      ]);
      expect(rules.length, 2);
      expect(rules.firstWhere((e) => e['action'] == 'reject')['protocol'], ['bittorrent']);
      expect(rules.firstWhere((e) => e['outbound'] == 'direct')['protocol'], ['quic']);
    });

    test('a name sing-box never reports is skipped', () {
      expect(
        protocolRulesFor(const [
          RoutingRule(match: RuleMatch.protocol, value: 'gopher', action: RuleAction.block),
        ]),
        isEmpty,
      );
    });
  });
}

/// The catalogue gained an entry that is not published by SagerNet, which is the
/// first time a preset's address has not been derivable from its id.
void _presetOrigins() {
  group('rule set addresses', () {
    RuleSetPreset preset(String id) => RuleSetPreset.byId(id)!;

    test('SagerNet presets are unchanged', () {
      final ads = preset('geosite-category-ads-all');
      expect(
        ads.urlFor(RuleSetSource.official, ''),
        'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/'
        'geosite-category-ads-all.srs',
      );
      expect(
        preset('geoip-id').urlFor(RuleSetSource.official, ''),
        'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-id.srs',
      );
    });

    test('a third-party preset points at its own repository and branch', () {
      final big = preset('geosite-ads-extended');
      expect(
        big.urlFor(RuleSetSource.official, ''),
        'https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/'
        'geosite-category-ads-all.srs',
      );
      // The jsdelivr mirror works for any GitHub repository, which is what keeps
      // this reachable on the networks GitHub itself is blocked on.
      expect(
        big.urlFor(RuleSetSource.jsdelivr, ''),
        'https://cdn.jsdelivr.net/gh/lyc8503/sing-box-rules@rule-set-geosite/'
        'geosite-category-ads-all.srs',
      );
    });

    test('a user mirror is not asked for a file it does not carry', () {
      // The mirror mirrors SagerNet; asking it for lyc8503's file would 404 and the
      // preset would show as unavailable for the wrong reason.
      expect(
        preset('geosite-ads-extended').urlFor(RuleSetSource.custom, 'https://mirror.example'),
        startsWith('https://raw.githubusercontent.com/lyc8503/'),
      );
      expect(
        preset('geoip-id').urlFor(RuleSetSource.custom, 'https://mirror.example'),
        'https://mirror.example/sing-geoip/rule-set/geoip-id.srs',
      );
    });

    test('the two ad lists are separate switches with separate files', () {
      // Same upstream filename, different ids -- so they cannot overwrite each
      // other on disk, and both can be on at once.
      expect(preset('geosite-ads-extended').fileName, preset('geosite-category-ads-all').fileName);
      expect(preset('geosite-ads-extended').id, isNot(preset('geosite-category-ads-all').id));
      expect(preset('geosite-ads-extended').action, RuleAction.block);
      // Off by default: it is a third-party download, so it is opted into.
      expect(preset('geosite-ads-extended').defaultOn, isFalse);
    });
  });
}

/// `graph.instagram.com` is Instagram's API, not an ad server, and SagerNet's list
/// blocks it. Seen live in the core's own log as a retry loop with nothing on screen
/// to explain it.
void _falsePositives() {
  group('ad-list false positives', () {
    List<Map<String, Object?>> routeRules({
      Set<String> presets = const {'geosite-category-ads-all'},
      List<RoutingRule> rules = const [],
    }) {
      final server = ShareLink.parse('trojan://pw@a.example:443#A')!;
      final config =
          ConfigBuilder(
            routing: RoutingSettings(enabledPresets: presets, rules: rules),
          ).buildMap(
            server,
            servers: [server],
            // A preset whose .srs is not on disk is left out of the config entirely --
            // sing-box treats a missing rule set as fatal -- so the paths have to be
            // there for the preset rules to exist at all.
            ruleSetPaths: {for (final id in presets) id: '/tmp/$id.srs'},
          );
      return ((config['route'] as Map)['rules'] as List).cast<Map<String, Object?>>();
    }

    int indexOfDomain(List<Map<String, Object?>> rules, String domain) =>
        rules.indexWhere((r) => (r['domain'] as List?)?.contains(domain) ?? false);

    test('the exception is emitted while a blocking preset is on', () {
      final rules = routeRules();
      final at = indexOfDomain(rules, 'graph.instagram.com');
      expect(at, isNot(-1));
      expect(rules[at]['outbound'], ConfigBuilder.proxyTag);
    });

    test('and not when nothing is blocking, so it costs nothing', () {
      // Only a routing preset on: there is no reject rule for it to guard against.
      expect(indexOfDomain(routeRules(presets: const {'geoip-id'}), 'graph.instagram.com'), -1);
      expect(indexOfDomain(routeRules(presets: const {}), 'graph.instagram.com'), -1);
    });

    test('a rule the user wrote still outranks it', () {
      // Someone who deliberately blocks the domain keeps that: their rule is emitted
      // first, and the core takes the first match.
      final rules = routeRules(
        rules: const [
          RoutingRule(
            match: RuleMatch.domain,
            value: 'graph.instagram.com',
            action: RuleAction.block,
          ),
        ],
      );
      final theirs = rules.indexWhere(
        (r) => (r['domain'] as List?)?.contains('graph.instagram.com') ?? false,
      );
      expect(rules[theirs]['action'], 'reject', reason: 'the user rule must come first');
    });

    test('it is checked before the rule sets that would reject it', () {
      final rules = routeRules();
      final exception = indexOfDomain(rules, 'graph.instagram.com');
      final ruleSet = rules.indexWhere((r) => r.containsKey('rule_set'));
      expect(ruleSet, isNot(-1));
      expect(exception, lessThan(ruleSet));
    });
  });
}

/// WARP as the exit rather than only a rule target.
///
/// The guard is the whole point: `final` naming an outbound that is not in the
/// config is not a degraded tunnel, it is one sing-box refuses to start.
void _warpAsFinal() {
  group('WARP as the final route', () {
    final account = WarpAccount(
      privateKey: 'key',
      peerPublicKey: 'peer',
      endpointHost: '162.159.192.1',
      endpointPort: 2408,
      addressV4: '172.16.0.2',
      addressV6: '2606:4700:110:8::2',
      reserved: const [1, 2, 3],
      registeredAt: DateTime.utc(2026),
    );

    Map<String, Object?> config({WarpAccount? warp, bool forAll = false}) {
      final server = ShareLink.parse('trojan://pw@a.example:443#A')!;
      return ConfigBuilder(
        routing: RoutingSettings(warp: warp, warpForAll: forAll),
      ).buildMap(server, servers: [server]);
    }

    String finalOf(Map<String, Object?> c) => (c['route'] as Map)['final'] as String;

    test('off, everything unmatched still exits at the proxy', () {
      expect(finalOf(config(warp: account)), ConfigBuilder.proxyTag);
    });

    test('on with an account, WARP becomes the exit', () {
      final c = config(warp: account, forAll: true);
      expect(finalOf(c), ConfigBuilder.warpTag);
      // And the endpoint it names is actually there.
      final endpoints = (c['endpoints'] as List).cast<Map<String, Object?>>();
      expect(endpoints.single['tag'], ConfigBuilder.warpTag);
    });

    test('on without an account, the proxy is used and no endpoint is named', () {
      // The stored preference outlives the account: turning WARP off leaves this
      // true, and acting on it would name an endpoint that is not in the config.
      final c = config(warp: null, forAll: true);
      expect(finalOf(c), ConfigBuilder.proxyTag);
      expect(c.containsKey('endpoints'), isFalse);
    });

    test('warpIsFinal is what answers, not the raw preference', () {
      expect(const RoutingSettings(warpForAll: true).warpForAll, isTrue);
      expect(const RoutingSettings(warpForAll: true).warpIsFinal, isFalse);
      expect(RoutingSettings(warpForAll: true, warp: account).warpIsFinal, isTrue);
    });

    test('the preference round-trips, and old profiles read as off', () {
      final stored = RoutingSettings(warp: account, warpForAll: true).toJson();
      expect(RoutingSettings.fromJson(stored).warpForAll, isTrue);
      expect(RoutingSettings.fromJson(stored..remove('warpForAll')).warpForAll, isFalse);
    });
  });
}
