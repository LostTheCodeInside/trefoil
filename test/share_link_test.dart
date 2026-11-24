import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/loopback_auth.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/usage_history.dart';
import 'package:trefoil/core/profile/warp.dart';
import 'package:trefoil/core/profile/xray_config.dart';
import 'package:trefoil/ui/config_screen.dart';

/// These assertions encode the output shape that was verified against the real
/// sing-box binary (`sing-box check`) for v1.13.19. If sing-box changes its schema,
/// these are the tests that should fail first.
void main() {
  _hysteriaBandwidth();
  _newProtocols();
  group('ShareLink.parse', () {
    test('vless over websocket with TLS', () {
      final out = ShareLink.parse(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?type=ws&security=tls&sni=sni.example&path=%2Fws&host=host.example#My%20Server',
      )!;

      expect(out.type, 'vless');
      expect(out.tag, 'My Server');
      expect(out.json['server'], 'example.com');
      expect(out.json['server_port'], 443);
      expect(out.json['uuid'], '11111111-2222-3333-4444-555555555555');
      expect((out.json['transport'] as Map)['type'], 'ws');
      expect((out.json['transport'] as Map)['path'], '/ws');
      expect((out.json['tls'] as Map)['server_name'], 'sni.example');
    });

    test('vless with REALITY gets a uTLS fingerprint even when the link omits fp', () {
      final out = ShareLink.parse(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?security=reality&pbk=somekey&sid=ff#R',
      )!;
      final tls = out.json['tls'] as Map;
      expect((tls['reality'] as Map)['public_key'], 'somekey');
      // REALITY without a fingerprint is trivially detectable, so we default one.
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
    });

    test('trojan is TLS even without an explicit security parameter', () {
      final out = ShareLink.parse('trojan://pw@example.com:443#T')!;
      expect((out.json['tls'] as Map)['enabled'], true);
    });

    test('shadowsocks SIP002 form', () {
      final userInfo = base64.encode(utf8.encode('aes-256-gcm:secret'));
      final out = ShareLink.parse('ss://$userInfo@example.com:8388#SS')!;
      expect(out.json['method'], 'aes-256-gcm');
      expect(out.json['password'], 'secret');
      expect(out.json['server_port'], 8388);
    });

    test('shadowsocks legacy fully-base64 form', () {
      final blob = base64.encode(utf8.encode('aes-256-gcm:secret@example.com:8388'));
      final out = ShareLink.parse('ss://$blob#Legacy')!;
      expect(out.json['server'], 'example.com');
      expect(out.json['server_port'], 8388);
    });

    test('vmess v2rayN json blob', () {
      final blob = base64.encode(
        utf8.encode(
          jsonEncode({
            'v': '2',
            'ps': 'VM',
            'add': 'example.com',
            'port': '443',
            'id': '11111111-2222-3333-4444-555555555555',
            'aid': '0',
            'net': 'ws',
            'path': '/p',
            'tls': 'tls',
          }),
        ),
      );
      final out = ShareLink.parse('vmess://$blob')!;
      expect(out.type, 'vmess');
      expect(out.tag, 'VM');
      // alter_id 0 is the default and must be omitted, not sent as 0.
      expect(out.json.containsKey('alter_id'), isFalse);
    });

    test('hysteria2 defaults to port 443 when the link omits it', () {
      final out = ShareLink.parse('hysteria2://pw@example.com#H')!;
      expect(out.json['server_port'], 443);
    });

    test('plain TCP produces no transport block', () {
      // sing-box rejects a transport object with an empty/unknown type.
      final out = ShareLink.parse('trojan://pw@example.com:443?type=tcp#T')!;
      expect(out.json.containsKey('transport'), isFalse);
    });

    test('post-quantum REALITY is routed to the Xray core, not rejected', () {
      final out = ShareLink.parse(
        'vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443'
        '?security=reality&pbk=KEY&sid=8e&sni=aws.amazon.com&pqv=LONGKEY&spx=%2Fx#PQ',
      )!;
      expect(out.requiresXray, isTrue);
      expect(out.isUsable, isTrue);
      // The link is retained verbatim: Xray's schema cannot be derived from the
      // sing-box outbound without losing mldsa65Verify.
      expect(out.link, contains('pqv=LONGKEY'));
    });

    test('a server without pqv stays on sing-box', () {
      final out = ShareLink.parse(
        'vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443'
        '?security=reality&pbk=KEY&sid=8e&sni=a.example&spx=%2Fx#OK',
      )!;
      expect(out.requiresXray, isFalse);
    });

    test('unparseable links return null rather than throwing', () {
      expect(ShareLink.parse('not-a-link'), isNull);
      expect(ShareLink.parse('vmess://@@@not-base64@@@'), isNull);
      expect(ShareLink.parse(''), isNull);
    });
  });

  group('ShareLink.parseSubscription', () {
    test('accepts a base64-wrapped body and skips unparseable lines', () {
      final body = base64.encode(
        utf8.encode(
          ['trojan://pw@a.example:443#A', 'garbage-line', 'trojan://pw@b.example:443#B'].join('\n'),
        ),
      );

      final out = ShareLink.parseSubscription(body, subscriptionId: 'sub1');
      expect(out.length, 2);
      expect(out.map((e) => e.tag), ['A', 'B']);
      expect(out.every((e) => e.subscriptionId == 'sub1'), isTrue);
    });

    test('deduplicates tags, because sing-box requires unique outbound tags', () {
      final body = [
        'trojan://pw@a.example:443#Same',
        'trojan://pw@b.example:443#Same',
        'trojan://pw@c.example:443#Same',
      ].join('\n');

      final tags = ShareLink.parseSubscription(body).map((e) => e.tag).toList();
      expect(tags.toSet().length, 3, reason: 'duplicate tags would make the config invalid');
      expect(tags.first, 'Same');
    });

    // The paste box always read this line; a subscription carrying it dropped it.
    test('keeps an AmneziaWG vpn:// line', () {
      const conf = '''
[Interface]
PrivateKey = cGxhY2Vob2xkZXItcHJpdmF0ZS1rZXktMzItYnl0ZXM=
Address = 10.8.1.2/32
Jc = 3
Jmin = 51
Jmax = 109
H1 = 410000001-416021364
I1 = <r 41>

# AmneziaWG-example
[Peer]
PublicKey = cGxhY2Vob2xkZXItcHVibGljLWtleS0zMi1ieXRlcyE=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.9:51820
''';
      // URL-safe and unpadded, the way the provider in the report sends it.
      final vpn = 'vpn://${base64Url.encode(utf8.encode(conf)).replaceAll('=', '')}';
      final body = base64.encode(utf8.encode(['trojan://pw@a.example:443#A', vpn].join('\n')));

      final out = ShareLink.parseSubscription(body, subscriptionId: 'sub1');
      expect(out.map((e) => e.tag), ['A', 'AmneziaWG-example']);
      expect(out.last.requiresAmnezia, isTrue);
      expect(out.last.subscriptionId, 'sub1');
      // Kept, so copying or exporting the server hands back what came in.
      expect(out.last.link, vpn);
    });
  });

  group('ConfigBuilder', () {
    final server = ShareLink.parse('trojan://pw@example.com:443#Server')!;

    test('re-tags the selected server so route rules can reference it', () {
      final config = const ConfigBuilder().buildMap(server);
      final outbounds = config['outbounds'] as List;
      expect((outbounds.first as Map)['tag'], ConfigBuilder.proxyTag);
      expect((config['route'] as Map)['final'], ConfigBuilder.proxyTag);
    });

    test('clash_api is present but opens no control port', () {
      final experimental = const ConfigBuilder().buildMap(server)['experimental'] as Map;
      expect(experimental.containsKey('clash_api'), isTrue);
      // An external_controller here would expose core control to any app on the device.
      expect((experimental['clash_api'] as Map).containsKey('external_controller'), isFalse);
    });

    test('per-app include and exclude are mutually exclusive', () {
      final include = const ConfigBuilder(
        perApp: PerAppRules(mode: PerAppMode.include, packages: ['com.a']),
      ).buildMap(server);
      final tun = (include['inbounds'] as List).first as Map;
      expect(tun['include_package'], ['com.a']);
      expect(tun.containsKey('exclude_package'), isFalse);
    });

    test('bypassLan adds a direct rule for private addresses', () {
      final rules =
          ((const ConfigBuilder(routingMode: RoutingMode.bypassLan).buildMap(server)['route']
                  as Map)['rules']
              as List);
      expect(rules.any((r) => (r as Map)['ip_is_private'] == true), isTrue);
    });

    // With a platform interface sing-box does not act on strict_route itself: it
    // hands it to OpenTun, which withholds allowBypass() on the VpnService. On by
    // default, because the bypass is how an app reads the real address on purpose.
    test('strict_route follows the setting, and is on by default', () {
      Map<Object?, Object?> tun(ConfigBuilder builder) =>
          (builder.buildMap(server)['inbounds'] as List).first as Map;
      expect(tun(const ConfigBuilder())['strict_route'], true);
      expect(tun(const ConfigBuilder(strictRoute: false))['strict_route'], false);
    });
  });

  group('redactSecrets', () {
    test('removes credentials but keeps the fields a handshake turns on', () {
      final config = const ConfigBuilder().build(
        ShareLink.parse(
          'vless://11111111-2222-3333-4444-555555555555@a.example:443'
          '?security=reality&sni=b.example&pbk=KEY&sid=ff#R',
        )!,
      );

      final redacted = redactSecrets(config);

      expect(redacted, isNot(contains('11111111-2222-3333-4444-555555555555')));
      expect(redacted, contains('"uuid": "***"'));
      // public_key and short_id are not secret and are exactly what a REALITY
      // failure hinges on, so they must survive redaction.
      expect(redacted, contains('KEY'));
      expect(redacted, contains('"short_id": "ff"'));
      expect(redacted, contains('"server_name": "b.example"'));
    });

    test('passes through anything that is not valid JSON', () {
      expect(redactSecrets('not json'), 'not json');
    });
  });

  group('XrayConfig', () {
    final pq = ShareLink.parse(
      'vless://11111111-2222-3333-4444-555555555555@1.2.3.4:31775'
      '?security=reality&fp=chrome&pbk=PUBKEY&sid=8e&sni=aws.amazon.com'
      '&pqv=VERIFYKEY&spx=%2Fabc&type=tcp&encryption=none#PQ',
    )!;

    test('carries mldsa65Verify, the reason the second core exists', () {
      final config = jsonDecode(XrayConfig.build(pq)!) as Map<String, Object?>;
      final stream = ((config['outbounds'] as List).first as Map)['streamSettings'] as Map;
      final reality = stream['realitySettings'] as Map;

      expect(stream['security'], 'reality');
      expect(reality['mldsa65Verify'], 'VERIFYKEY');
      expect(reality['publicKey'], 'PUBKEY');
      expect(reality['shortId'], '8e');
      expect(reality['serverName'], 'aws.amazon.com');
      expect(reality['spiderX'], '/abc');
    });

    const loopback = LoopbackAuth(
      xrayPort: 23456,
      amneziaPort: 24567,
      username: 'u1',
      password: 'p1',
    );

    test('exposes SOCKS on loopback only, and only with the session credentials', () {
      final config = jsonDecode(XrayConfig.build(pq, loopback: loopback)!) as Map<String, Object?>;
      final inbound = (config['inbounds'] as List).first as Map;
      final settings = inbound['settings'] as Map;
      expect(inbound['listen'], '127.0.0.1');
      expect(inbound['port'], loopback.xrayPort);
      expect(settings['udp'], true);
      // Any app on the device can reach loopback. Without this, any of them could
      // use the tunnel, and learn the server it exits from.
      expect(settings['auth'], 'password');
      expect(settings['accounts'], [
        {'user': 'u1', 'pass': 'p1'},
      ]);
    });

    test('a config built without a session set still demands credentials', () {
      final inbound = ((jsonDecode(XrayConfig.build(pq)!) as Map)['inbounds'] as List).first as Map;
      final settings = inbound['settings'] as Map;
      expect(settings['auth'], 'password');
      final account = (settings['accounts'] as List).single as Map;
      expect(account['user'], isNotEmpty);
      expect(account['pass'], hasLength(48));
      expect(inbound['port'], inInclusiveRange(LoopbackAuth.portFloor, LoopbackAuth.portCeiling));
    });

    test('sing-box reaches the Xray server through that inbound', () {
      final singBox = const ConfigBuilder().buildMap(pq, loopback: loopback);
      final outbounds = (singBox['outbounds'] as List).cast<Map<String, Object?>>();

      // Routing always targets the selector, whichever core carries the traffic.
      expect((singBox['route'] as Map)['final'], ConfigBuilder.proxyTag);
      final selector = outbounds.firstWhere((o) => o['tag'] == ConfigBuilder.proxyTag);
      expect(selector['type'], 'selector');
      expect(selector['default'], pq.tag);

      final socks = outbounds.firstWhere((o) => o['tag'] == pq.tag);
      expect(socks['type'], 'socks');
      expect(socks['server'], '127.0.0.1');
      expect(socks['server_port'], loopback.xrayPort);
      expect(socks['username'], loopback.username);
      expect(socks['password'], loopback.password);
    });

    test('other servers stay selectable alongside an Xray one', () {
      // Only one Xray instance runs at a time, so a second Xray-only server cannot
      // be a live member — but sing-box-native servers still can.
      final native = ShareLink.parse('trojan://pw@native.example:443#Native')!;
      final outbounds =
          (const ConfigBuilder().buildMap(pq, servers: [pq, native])['outbounds'] as List)
              .cast<Map<String, Object?>>();
      final tags = outbounds.map((o) => o['tag']).toList();
      expect(tags, contains('Native'));
      expect(tags, contains(pq.tag));
      expect(tags, contains(ConfigBuilder.autoTag));
    });

    test('returns null for links that do not need it', () {
      final plain = ShareLink.parse('trojan://pw@a.example:443#T')!;
      expect(XrayConfig.build(plain), isNull);
    });
  });

  group('ProfileData migration', () {
    test('v1 documents are flagged for re-import', () {
      // v1 stored no share link, so an Xray-only server saved back then is
      // indistinguishable from an ordinary one and would silently run on sing-box.
      final v1 = ProfileData(
        servers: [ShareLink.parse('trojan://pw@a.example:443#A')!],
        needsReimport: true,
      );
      expect(v1.needsReimport, isTrue);
      expect(v1.copyWith(needsReimport: false).needsReimport, isFalse);
    });

    test('an empty v1 profile has nothing to re-import', () {
      expect(const ProfileData().needsReimport, isFalse);
    });
  });

  group('routing rules', () {
    final server = ShareLink.parse('trojan://pw@example.com:443#S')!;
    const paths = {'geosite-category-ads-all': '/tmp/ads.srs', 'geoip-id': '/tmp/id.srs'};

    List<Map<String, Object?>> rulesOf(ConfigBuilder builder) =>
        ((builder.buildMap(server, ruleSetPaths: paths)['route'] as Map)['rules'] as List)
            .cast<Map<String, Object?>>();

    test('user rules are evaluated before presets', () {
      final rules = rulesOf(
        const ConfigBuilder(
          routing: RoutingSettings(
            enabledPresets: {'geosite-category-ads-all'},
            rules: [
              RoutingRule(
                match: RuleMatch.domainSuffix,
                value: 'ads.example',
                action: RuleAction.proxy,
              ),
            ],
          ),
        ),
      );
      final userIndex = rules.indexWhere((r) => r.containsKey('domain_suffix'));
      final presetIndex = rules.indexWhere((r) => r.containsKey('rule_set'));
      expect(userIndex, isNonNegative);
      expect(presetIndex, isNonNegative);
      expect(userIndex, lessThan(presetIndex), reason: 'an explicit allow must beat the ad list');
    });

    // A site that only works from one country goes through that country's server.
    test('a rule can name its server, and falls back when that server is not there', () {
      final other = ShareLink.parse('trojan://pw@other.example:443#Other')!;
      Map<String, Object?> ruleFor(String target) =>
          ((ConfigBuilder(
                        routing: RoutingSettings(
                          rules: [
                            RoutingRule(
                              match: RuleMatch.domainSuffix,
                              value: 'youtube.com',
                              action: RuleAction.proxy,
                              server: target,
                            ),
                          ],
                        ),
                      ).buildMap(server, servers: [server, other])['route']
                      as Map)['rules']
                  as List)
              .cast<Map<String, Object?>>()
              .firstWhere((r) => r.containsKey('domain_suffix'));

      expect(ruleFor('Other')['outbound'], 'Other');
      // Gone since, or never in this config: the selected server, not a broken tunnel.
      expect(ruleFor('Gone')['outbound'], ConfigBuilder.proxyTag);
    });

    test('a named server survives storage, and only a proxy rule keeps one', () {
      const rule = RoutingRule(
        match: RuleMatch.domain,
        value: 'a.example',
        action: RuleAction.proxy,
        server: 'Other',
      );
      expect(RoutingRule.fromJson(rule.toJson()).server, 'Other');
      expect(rule.copyWith(enabled: false).server, 'Other');
      expect(rule.copyWith(action: RuleAction.direct).server, isNull);
    });

    test('rules sharing a field and action collapse into one', () {
      final rules = rulesOf(
        const ConfigBuilder(
          routing: RoutingSettings(
            rules: [
              RoutingRule(match: RuleMatch.domainSuffix, value: 'a.com', action: RuleAction.direct),
              RoutingRule(match: RuleMatch.domainSuffix, value: 'b.com', action: RuleAction.direct),
            ],
          ),
        ),
      );
      final direct = rules.firstWhere((r) => r.containsKey('domain_suffix'));
      expect(direct['domain_suffix'], ['a.com', 'b.com']);
    });

    test('disabled rules are omitted entirely', () {
      final rules = rulesOf(
        const ConfigBuilder(
          routing: RoutingSettings(
            rules: [
              RoutingRule(
                match: RuleMatch.domain,
                value: 'off.example',
                action: RuleAction.block,
                enabled: false,
              ),
            ],
          ),
        ),
      );
      expect(rules.any((r) => r.containsKey('domain')), isFalse);
    });

    test('block becomes a reject action, not an outbound', () {
      final rules = rulesOf(
        const ConfigBuilder(
          routing: RoutingSettings(
            rules: [
              RoutingRule(match: RuleMatch.domain, value: 'x.example', action: RuleAction.block),
            ],
          ),
        ),
      );
      final blocked = rules.firstWhere((r) => r.containsKey('domain'));
      expect(blocked['action'], 'reject');
      expect(blocked.containsKey('outbound'), isFalse);
    });

    test('a preset with no downloaded file is left out of both rules and rule_set', () {
      // Referencing a rule set whose file is missing is a fatal config error, so a
      // failed download must never reach the config.
      final config = const ConfigBuilder(
        routing: RoutingSettings(enabledPresets: {'geosite-private'}),
      ).buildMap(server, ruleSetPaths: paths);
      final route = config['route'] as Map;
      expect(route.containsKey('rule_set'), isFalse);
      expect((route['rules'] as List).any((r) => (r as Map).containsKey('rule_set')), isFalse);
    });

    test('rule_set entries are local files, never remote URLs', () {
      final route =
          const ConfigBuilder(routing: RoutingSettings(enabledPresets: {'geoip-id'}))
                  .buildMap(server, ruleSetPaths: paths)['route']
              as Map;
      final sets = (route['rule_set'] as List).cast<Map<String, Object?>>();
      expect(sets.single['type'], 'local');
      expect(sets.single['path'], '/tmp/id.srs');
    });

    test('settings survive a round trip through storage', () {
      final original = const ConfigBuilder(
        enableIpv6: true,
        perApp: PerAppRules(mode: PerAppMode.exclude, packages: ['com.a']),
        routing: RoutingSettings(
          enabledPresets: {'geoip-id'},
          rules: [
            RoutingRule(match: RuleMatch.ipCidr, value: '10.0.0.0/8', action: RuleAction.direct),
          ],
        ),
      );
      final restored = ConfigBuilder.fromJson(original.toJson());
      expect(restored.enableIpv6, isTrue);
      expect(restored.perApp.mode, PerAppMode.exclude);
      expect(restored.routing.enabledPresets, {'geoip-id'});
      expect(restored.routing.rules.single.value, '10.0.0.0/8');
    });

    test('copyWith preserves fields the caller did not mention', () {
      // Rebuilding this object by hand is how routing got silently dropped once.
      final base = const ConfigBuilder(routing: RoutingSettings(enabledPresets: {'geoip-id'}));
      expect(base.copyWith(enableIpv6: true).routing.enabledPresets, {'geoip-id'});
    });
  });

  group('server groups', () {
    final a = ShareLink.parse('trojan://pw@a.example:443#A')!;
    final b = ShareLink.parse('trojan://pw@b.example:443#B')!;

    test('a single server needs no auto group', () {
      final outbounds = (const ConfigBuilder().buildMap(a, servers: [a])['outbounds'] as List)
          .cast<Map<String, Object?>>();
      expect(outbounds.any((o) => o['tag'] == ConfigBuilder.autoTag), isFalse);
      final selector = outbounds.firstWhere((o) => o['tag'] == ConfigBuilder.proxyTag);
      expect(selector['outbounds'], ['A']);
    });

    test('several servers get a urltest group listed first', () {
      final outbounds = (const ConfigBuilder().buildMap(a, servers: [a, b])['outbounds'] as List)
          .cast<Map<String, Object?>>();
      final selector = outbounds.firstWhere((o) => o['tag'] == ConfigBuilder.proxyTag);
      expect(selector['outbounds'], [ConfigBuilder.autoTag, 'A', 'B']);

      final auto = outbounds.firstWhere((o) => o['tag'] == ConfigBuilder.autoTag);
      expect(auto['type'], 'urltest');
      expect(auto['outbounds'], ['A', 'B']);
      expect(auto['url'], ConfigBuilder.defaultTestUrl);
    });

    test('switching servers does not interrupt connections in flight', () {
      final outbounds = (const ConfigBuilder().buildMap(a, servers: [a, b])['outbounds'] as List)
          .cast<Map<String, Object?>>();
      final selector = outbounds.firstWhere((o) => o['tag'] == ConfigBuilder.proxyTag);
      expect(selector['interrupt_exist_connections'], false);
    });
  });

  group('quick modes', () {
    final server = ShareLink.parse('trojan://pw@a.example:443#A')!;

    test('every mode is present in the config, so switching needs no reconnect', () {
      final config = const ConfigBuilder().buildMap(server);
      final rules = (config['route'] as Map)['rules'] as List;
      final modes = rules
          .whereType<Map<String, Object?>>()
          .where((r) => r.containsKey('clash_mode'))
          .map((r) => r['clash_mode'])
          .toList();
      expect(modes, [ConfigBuilder.modeDirect, ConfigBuilder.modeGlobal]);
      expect(
        ((config['experimental'] as Map)['clash_api'] as Map)['default_mode'],
        ConfigBuilder.modeRule,
      );
    });

    test('mode rules are checked before user rules', () {
      // Picking Direct must win over a rule that sends something to the proxy,
      // otherwise the quick switch would only half apply.
      final rules =
          ((const ConfigBuilder(
                        routing: RoutingSettings(
                          rules: [
                            RoutingRule(
                              match: RuleMatch.domainSuffix,
                              value: 'a.com',
                              action: RuleAction.proxy,
                            ),
                          ],
                        ),
                      ).buildMap(server)['route']
                      as Map)['rules']
                  as List)
              .cast<Map<String, Object?>>();
      final modeIndex = rules.indexWhere((r) => r.containsKey('clash_mode'));
      final userIndex = rules.indexWhere((r) => r.containsKey('domain_suffix'));
      expect(modeIndex, lessThan(userIndex));
    });
  });

  group('CustomOutbound', () {
    test('accepts a bare outbound object', () {
      final out = CustomOutbound.parse(
        '{"type":"vmess","server":"a.example","server_port":443,"uuid":"x"}',
        name: 'Hand written',
      );
      expect(out.type, 'vmess');
      expect(out.tag, 'Hand written');
      expect(out.json['tag'], 'Hand written');
    });

    test('pulls the server out of a whole config', () {
      final out = CustomOutbound.parse('''
        {"outbounds":[
          {"type":"selector","tag":"proxy","outbounds":["a"]},
          {"type":"direct","tag":"direct"},
          {"type":"trojan","tag":"a","server":"b.example","server_port":443}
        ]}
      ''');
      expect(out.type, 'trojan');
      expect(out.tag, 'a');
    });

    test('rejects plumbing outbounds, which are not servers', () {
      expect(() => CustomOutbound.parse('{"type":"direct"}'), throwsA(isA<FormatException>()));
      expect(
        () => CustomOutbound.parse('{"outbounds":[{"type":"direct","tag":"d"}]}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('reports bad JSON and missing type distinctly', () {
      expect(() => CustomOutbound.parse('not json'), throwsA(isA<FormatException>()));
      expect(() => CustomOutbound.parse('{"server":"a"}'), throwsA(isA<FormatException>()));
      expect(() => CustomOutbound.parse('[]'), throwsA(isA<FormatException>()));
    });

    test('falls back to the server address when no name is given', () {
      final out = CustomOutbound.parse('{"type":"vmess","server":"a.example"}');
      expect(out.tag, 'a.example');
    });
  });

  group('WARP', () {
    final server = ShareLink.parse('trojan://pw@a.example:443#A')!;
    final account = WarpAccount(
      privateKey: 'cHJpdmF0ZQ==',
      peerPublicKey: 'cHVibGlj',
      endpointHost: '162.159.192.1',
      endpointPort: 2408,
      addressV4: '172.16.0.2',
      addressV6: '2606:4700:110::1',
      reserved: [1, 2, 3],
      registeredAt: DateTime(2026),
    );

    Map<String, Object?> configWith(RoutingSettings routing) =>
        ConfigBuilder(routing: routing).buildMap(server);

    test('becomes a wireguard endpoint carrying the reserved bytes', () {
      final config = configWith(RoutingSettings(warp: account));
      final endpoint = (config['endpoints'] as List).single as Map<String, Object?>;
      expect(endpoint['type'], 'wireguard');
      expect(endpoint['tag'], ConfigBuilder.warpTag);
      final peer = (endpoint['peers'] as List).single as Map<String, Object?>;
      // Cloudflare drops packets without these; they identify the account.
      expect(peer['reserved'], [1, 2, 3]);
      expect(peer['port'], 2408);
    });

    test('chains through the proxy or dials out, as configured', () {
      final chained = (configWith(RoutingSettings(warp: account))['endpoints'] as List).single;
      expect((chained as Map)['detour'], ConfigBuilder.proxyTag);

      // Dialling out is the *absence* of the field, not a detour to `direct`.
      // sing-box refuses to dial through a direct outbound that carries no options,
      // on the grounds that it is dialling out written the long way round.
      final direct =
          (configWith(RoutingSettings(warp: account, warpThroughProxy: false))['endpoints'] as List)
              .single;
      expect((direct as Map).containsKey('detour'), isFalse);
    });

    test('a WARP rule with no account is dropped, not left dangling', () {
      // Naming an outbound that is not in the config is fatal to starting the
      // tunnel, so a stale rule must never survive into it.
      final config = configWith(
        const RoutingSettings(
          rules: [
            RoutingRule(
              match: RuleMatch.domainSuffix,
              value: 'openai.com',
              action: RuleAction.warp,
            ),
          ],
        ),
      );
      expect(config.containsKey('endpoints'), isFalse);
      final rules = (config['route'] as Map)['rules'] as List;
      expect(rules.any((r) => (r as Map)['outbound'] == ConfigBuilder.warpTag), isFalse);
    });

    test('survives a settings round trip', () {
      final restored = ConfigBuilder.fromJson(
        ConfigBuilder(routing: RoutingSettings(warp: account)).toJson(),
      );
      expect(restored.routing.warp?.peerPublicKey, 'cHVibGlj');
      expect(restored.routing.warp?.reserved, [1, 2, 3]);
    });
  });

  group('SubscriptionUsage', () {
    test('parses the header providers actually send', () {
      final usage = SubscriptionUsage.parse(
        'upload=455727941; download=6174315083; total=107374182400; expire=1671815872',
      );
      expect(usage.used, 455727941 + 6174315083);
      expect(usage.total, 107374182400);
      expect(usage.expiresAt?.year, 2022);
      expect(usage.fraction, closeTo(0.0617, 0.001));
    });

    test('treats a zero total as unlimited, not as fully used', () {
      // Several providers report unlimited plans this way; dividing by it would
      // show a full bar to someone who has used almost nothing.
      final usage = SubscriptionUsage.parse('upload=1; download=1; total=0');
      expect(usage.fraction, isNull);
      expect(usage.used, 2);
    });

    test('treats a zero expiry as never expiring', () {
      expect(SubscriptionUsage.parse('expire=0').expiresAt, isNull);
    });

    test('missing fields stay null rather than becoming zero', () {
      final usage = SubscriptionUsage.parse('total=100');
      expect(usage.used, isNull, reason: 'nothing reported is not the same as none used');
      expect(usage.fraction, isNull);
    });

    test('survives junk without throwing', () {
      for (final input in ['', '   ', 'garbage', 'upload=; download=abc', ';;;']) {
        expect(() => SubscriptionUsage.parse(input), returnsNormally, reason: input);
      }
      expect(SubscriptionUsage.parse(null).isEmpty, isTrue);
    });

    test('round trips through storage', () {
      const original = SubscriptionUsage(upload: 1, download: 2, total: 3);
      final restored = SubscriptionUsage.fromJson(original.toJson());
      expect(restored.used, 3);
      expect(restored.total, 3);
    });
  });

  group('UsageHistoryStore', () {
    DailyUsage day(int daysAgo, int up, int down) {
      final now = DateTime.now();
      return DailyUsage(
        date: DateTime(now.year, now.month, now.day - daysAgo),
        upload: up,
        download: down,
      );
    }

    test('fills quiet days so the time axis stays honest', () {
      // Skipping empty days would silently compress the axis and make a gap look
      // like continuous use.
      final filled = UsageHistoryStore.lastDays([day(0, 1, 2), day(3, 5, 5)], 5);
      expect(filled.length, 5);
      expect(filled.last.total, 3, reason: 'today is last');
      expect(filled.where((d) => d.total == 0).length, 3);
    });

    test('days come back oldest first, ready to plot', () {
      final filled = UsageHistoryStore.lastDays([day(0, 1, 1)], 3);
      expect(filled.first.date.isBefore(filled.last.date), isTrue);
    });

    test('monthly total counts only the month asked for', () {
      final now = DateTime.now();
      final history = [
        DailyUsage(date: DateTime(now.year, now.month, 1), upload: 10, download: 10),
        DailyUsage(date: DateTime(now.year, now.month - 1, 15), upload: 99, download: 99),
      ];
      expect(UsageHistoryStore.totalInMonth(history, now), 20);
    });
  });
}

/// The protocols added alongside Clash import. Each shape was checked against the
/// real sing-box binary (`sing-box check`) for v1.13.19.
void _newProtocols() {
  group('ShareLink.parse, later protocols', () {
    test('anytls', () {
      final out = ShareLink.parse('anytls://pw@a.example:443?sni=sni.example#AnyTLS')!;
      expect(out.type, 'anytls');
      expect(out.tag, 'AnyTLS');
      expect(out.json['server'], 'a.example');
      expect(out.json['server_port'], 443);
      expect(out.json['password'], 'pw');
      // anytls is TLS by definition, like trojan, so it is on without being asked.
      expect((out.json['tls'] as Map)['enabled'], isTrue);
      expect((out.json['tls'] as Map)['server_name'], 'sni.example');
    });

    test('anytls with a user:password userinfo keeps only the password', () {
      final out = ShareLink.parse('anytls://user:pw@a.example:443#A')!;
      expect(out.json['password'], 'pw');
    });

    test('hysteria v1 takes its credential from the query, not the userinfo', () {
      final out = ShareLink.parse(
        'hysteria://h.example:443?auth=pw&peer=sni.example&upmbps=30&downmbps=200'
        '&alpn=hysteria&insecure=1#HY1',
      )!;
      expect(out.type, 'hysteria');
      expect(out.json['auth_str'], 'pw');
      expect(out.json['up_mbps'], 30);
      expect(out.json['down_mbps'], 200);
      // `peer` is hysteria's own spelling of the server name.
      expect((out.json['tls'] as Map)['server_name'], 'sni.example');
      expect((out.json['tls'] as Map)['insecure'], isTrue);
    });

    test('socks with base64 credentials', () {
      // base64 of "u:pw" with the padding stripped, which is how v2rayN writes it.
      final out = ShareLink.parse('socks://dTpwdw@10.0.0.9:1080#SOCKS')!;
      expect(out.type, 'socks');
      expect(out.json['version'], '5');
      expect(out.json['username'], 'u');
      expect(out.json['password'], 'pw');
    });

    test('socks with readable credentials, and with none at all', () {
      final readable = ShareLink.parse('socks5://user:pass@10.0.0.9:1080#S')!;
      expect(readable.json['username'], 'user');
      expect(readable.json['password'], 'pass');

      final anonymous = ShareLink.parse('socks://10.0.0.9:1080#S')!;
      expect(anonymous.json.containsKey('username'), isFalse);
      expect(anonymous.json.containsKey('password'), isFalse);
    });

    test('a malformed link of a known scheme still returns null', () {
      expect(ShareLink.parse('anytls://a.example:443'), isNull, reason: 'no password');
      expect(ShareLink.parse('socks://10.0.0.9'), isNull, reason: 'no port');
      expect(ShareLink.parse('hysteria://:443'), isNull, reason: 'no host');
    });

    test('an unknown scheme is still ignored rather than guessed at', () {
      expect(ShareLink.parse('ssr://whatever'), isNull);
      expect(ShareLink.parse('https://example.com/subscription'), isNull);
    });
  });
}

/// sing-box refuses to build a hysteria v1 outbound with no upload speed, and it
/// refuses the *whole config* — every other server included. Verified against the
/// real binary: `initialize outbound[0]: missing upload speed`.
void _hysteriaBandwidth() {
  group('hysteria v1 bandwidth is never absent', () {
    test('a link that omits it still produces both fields', () {
      final out = ShareLink.parse('hysteria://h.example:443?auth=pw#A')!;
      expect(out.json['up_mbps'], isA<int>());
      expect(out.json['down_mbps'], isA<int>());
      expect(out.json['up_mbps'] as int, greaterThan(0));
      expect(out.json['down_mbps'] as int, greaterThan(0));
    });

    test('a value of zero is treated as absent rather than passed through', () {
      final out = ShareLink.parse('hysteria://h.example:443?auth=pw&upmbps=0&downmbps=0#A')!;
      expect(out.json['up_mbps'] as int, greaterThan(0));
      expect(out.json['down_mbps'] as int, greaterThan(0));
    });

    test('a real value is kept', () {
      final out = ShareLink.parse('hysteria://h.example:443?auth=pw&upmbps=80&downmbps=400#A')!;
      expect(out.json['up_mbps'], 80);
      expect(out.json['down_mbps'], 400);
    });
  });
}
