import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/loopback_auth.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/warp.dart';
import 'package:trefoil/core/profile/wireguard_config.dart';

/// WireGuard is a sing-box *endpoint*, not an outbound — it stopped being one in
/// 1.11. Endpoints share the tag namespace with outbounds, which is what lets such a
/// server sit in the selector and be latency-tested like any other; that was checked
/// against the real binary before any of this was written.
const _conf = '''
[Interface]
# a comment, and a blank line follow
PrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=
Address = 10.0.0.2/32, fd00::2/128
MTU = 1408
DNS = 1.1.1.1

[Peer]
PublicKey = bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI=
PresharedKey = cHNrIHBzayBwc2sgcHNrIHBzayBwc2sgcHNrIHBzMg==
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
''';

const _link =
    'wireguard://aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI%3D@1.2.3.4:51820'
    '?publickey=bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI%3D&address=10.7.0.2/32'
    '&mtu=1420&reserved=1,2,3#WG%20Link';

void main() {
  group('the .conf file', () {
    final parsed = WireGuardConfig.parse(_conf, name: 'Home')!;

    test('is recognised without being mistaken for a link', () {
      expect(WireGuardConfig.looksLikeConf(_conf), isTrue);
      expect(WireGuardConfig.looksLikeConf('vless://x@y:443'), isFalse);
      expect(WireGuardConfig.looksLikeConf('the [Interface] is nice'), isFalse);
    });

    test('becomes an endpoint, not an outbound', () {
      expect(parsed.type, 'wireguard');
      expect(parsed.isEndpoint, isTrue);
    });

    test('carries the interface across', () {
      expect(parsed.json['private_key'], 'aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=');
      expect(parsed.json['address'], ['10.0.0.2/32', 'fd00::2/128']);
      expect(parsed.json['mtu'], 1408);
    });

    test('and the peer', () {
      final peer = (parsed.json['peers'] as List).first as Map;
      expect(peer['address'], 'vpn.example.com');
      expect(peer['port'], 51820);
      expect(peer['public_key'], 'bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI=');
      expect(peer['pre_shared_key'], 'cHNrIHBzayBwc2sgcHNrIHBzayBwc2sgcHNrIHBzMg==');
      expect(peer['persistent_keepalive_interval'], 25);
      // Everything, whatever the file said: this is a proxy, not a split tunnel.
      // A partial allowed_ips would route the rest nowhere, which reads as a
      // tunnel that connects and carries nothing.
      expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
    });

    test('the server list can show and search it', () {
      // Both read off the peer, since an endpoint has no server/server_port.
      expect(parsed.server, 'vpn.example.com');
      expect(parsed.serverPort, 51820);
    });

    test('a bare address gets the prefix sing-box requires', () {
      final out = WireGuardConfig.parse('''
[Interface]
PrivateKey = k
Address = 10.0.0.5
[Peer]
PublicKey = p
Endpoint = h.example:1234
''')!;
      expect(out.json['address'], ['10.0.0.5/32']);
    });

    test('an IPv6 endpoint in brackets', () {
      final out = WireGuardConfig.parse('''
[Interface]
PrivateKey = k
Address = fd00::2/128
[Peer]
PublicKey = p
Endpoint = [2606:4700::1111]:51820
''')!;
      final peer = (out.json['peers'] as List).first as Map;
      expect(peer['address'], '2606:4700::1111');
      expect(peer['port'], 51820);
    });

    test('a missing key, peer or address is refused rather than half-built', () {
      expect(WireGuardConfig.parse('[Interface]\nAddress = 10.0.0.2/32'), isNull);
      expect(
        WireGuardConfig.parse('[Interface]\nPrivateKey = k\n[Peer]\nEndpoint = h:1'),
        isNull,
        reason: 'no public key',
      );
      expect(
        WireGuardConfig.parse('[Interface]\nPrivateKey = k\n[Peer]\nPublicKey = p'),
        isNull,
        reason: 'no endpoint',
      );
      expect(
        WireGuardConfig.parse('[Interface]\nPrivateKey = k\n[Peer]\nPublicKey = p\nEndpoint = h:1'),
        isNull,
        reason: 'no address',
      );
    });
  });

  group('the wireguard:// link', () {
    final parsed = ShareLink.parse(_link)!;

    test('parses through the ordinary share-link path', () {
      expect(parsed.type, 'wireguard');
      expect(parsed.isEndpoint, isTrue);
      expect(parsed.tag, 'WG Link');
      expect(parsed.json['mtu'], 1420);
    });

    test('reserved bytes, as a triple or as base64', () {
      final peer = (parsed.json['peers'] as List).first as Map;
      expect(peer['reserved'], [1, 2, 3]);
      // Cloudflare-style clients write the same three bytes base64-encoded.
      final b64 = ShareLink.parse(_link.replaceAll('reserved=1,2,3', 'reserved=AQID'))!;
      expect(((b64.json['peers'] as List).first as Map)['reserved'], [1, 2, 3]);
    });

    test('a nonsense reserved value is dropped rather than emitted', () {
      final bad = ShareLink.parse(_link.replaceAll('reserved=1,2,3', 'reserved=9,9'))!;
      expect(((bad.json['peers'] as List).first as Map).containsKey('reserved'), isFalse);
    });

    test('no keepalive is emitted when none was asked for', () {
      final peer = (parsed.json['peers'] as List).first as Map;
      expect(peer.containsKey('persistent_keepalive_interval'), isFalse);
    });

    test('a link without a key or an address is refused', () {
      expect(ShareLink.parse('wireguard://@1.2.3.4:51820?address=10.0.0.2/32'), isNull);
      expect(ShareLink.parse('wireguard://key@1.2.3.4:51820?publickey=p'), isNull);
    });
  });

  group('in the generated config', () {
    final wg = WireGuardConfig.parse(_conf, name: 'WG')!;
    final trojan = ShareLink.parse('trojan://pw@t.example:443#Trojan')!;

    Map<String, Object?> build({
      List<dynamic> servers = const [],
      dynamic selected,
      WarpAccount? warp,
    }) =>
        ConfigBuilder(routing: RoutingSettings(warp: warp))
            .buildMap(selected ?? wg, servers: servers.cast());

    test('a WireGuard server lands in endpoints, the rest in outbounds', () {
      final c = build(servers: [wg, trojan]);
      final outboundTags = (c['outbounds'] as List)
          .cast<Map<String, Object?>>()
          .map((e) => e['tag'])
          .toList();
      final endpointTags = (c['endpoints'] as List)
          .cast<Map<String, Object?>>()
          .map((e) => e['tag'])
          .toList();
      expect(endpointTags, ['WG']);
      expect(outboundTags, contains('Trojan'));
      expect(outboundTags, isNot(contains('WG')));
    });

    test('both kinds sit in the selector and the latency test together', () {
      final c = build(servers: [wg, trojan]);
      final outbounds = (c['outbounds'] as List).cast<Map<String, Object?>>();
      final selector = outbounds.firstWhere((e) => e['type'] == 'selector');
      final urltest = outbounds.firstWhere((e) => e['type'] == 'urltest');
      expect(selector['outbounds'], ['auto', 'WG', 'Trojan']);
      expect(urltest['outbounds'], ['WG', 'Trojan']);
    });

    test('a WireGuard server alone still produces a usable config', () {
      final c = build(servers: [wg]);
      expect((c['endpoints'] as List).length, 1);
      expect((c['route'] as Map)['final'], ConfigBuilder.proxyTag);
    });

    test('WARP and a WireGuard server coexist in one endpoints array', () {
      final account = WarpAccount(
        privateKey: 'k',
        peerPublicKey: 'p',
        endpointHost: '162.159.192.1',
        endpointPort: 2408,
        addressV4: '172.16.0.2',
        addressV6: '2606:4700:110:8::2',
        reserved: const [1, 2, 3],
        registeredAt: DateTime.utc(2026),
      );
      final tags = ((build(servers: [wg], warp: account)['endpoints']) as List)
          .cast<Map<String, Object?>>()
          .map((e) => e['tag'])
          .toList();
      expect(tags, ['WG', ConfigBuilder.warpTag]);
    });

    test('no endpoints key at all when there is nothing to put in it', () {
      // sing-box rejects an endpoints array that is present and empty.
      expect(build(servers: [trojan], selected: trojan).containsKey('endpoints'), isFalse);
    });

    test('a server named after a generated tag is dropped, not allowed to shadow it', () {
      // "warp" or "proxy" as a server name would replace the real one, and the
      // selector could end up pointing at itself.
      final impostor = trojan.withTag(ConfigBuilder.warpTag);
      final c = build(servers: [trojan, impostor], selected: trojan);
      final outbounds = (c['outbounds'] as List).cast<Map<String, Object?>>();
      final selector = outbounds.firstWhere((e) => e['type'] == 'selector');
      expect(selector['outbounds'], isNot(contains(ConfigBuilder.warpTag)));
    });
  });

  // sing-box refuses to dial through a direct outbound that carries no options: it
  // is dialling out written the long way round, so it treats the indirection as a
  // mistake. The refusal is lazy — it happens on the first packet, from
  // `DetourDialer.init`, so `sing-box check` passes a config that then carries no
  // traffic at all and reports only "detour to an empty direct outbound makes no
  // sense" once per second. Structural, and cheap to assert, so it is asserted here.
  group('nothing detours to the bare direct outbound', () {
    final wg = WireGuardConfig.parse(_conf, name: 'WG')!;
    final trojan = ShareLink.parse('trojan://pw@t.example:443#Trojan')!;
    final account = WarpAccount(
      privateKey: 'k',
      peerPublicKey: 'p',
      endpointHost: '162.159.192.1',
      endpointPort: 2408,
      addressV4: '172.16.0.2',
      addressV6: 'fd01::2',
      reserved: const [1, 2, 3],
      registeredAt: DateTime(2026),
    );

    /// Every member of a config that can carry a `detour`, whichever array it is in.
    Iterable<Map<String, Object?>> members(Map<String, Object?> config) => [
      ...(config['outbounds'] as List? ?? []).cast<Map<String, Object?>>(),
      ...(config['endpoints'] as List? ?? []).cast<Map<String, Object?>>(),
    ];

    final cases = <String, Map<String, Object?>>{
      'a WireGuard server alone': ConfigBuilder(routing: const RoutingSettings())
          .buildMap(wg, servers: [wg]),
      'WireGuard beside another protocol': ConfigBuilder(routing: const RoutingSettings())
          .buildMap(wg, servers: [wg, trojan]),
      'WARP dialling out on its own': ConfigBuilder(
        routing: RoutingSettings(warp: account, warpThroughProxy: false),
      ).buildMap(trojan, servers: [trojan]),
      'WARP chained behind the proxy': ConfigBuilder(routing: RoutingSettings(warp: account))
          .buildMap(trojan, servers: [trojan]),
      'WARP as the exit for everything': ConfigBuilder(
        routing: RoutingSettings(warp: account, warpThroughProxy: false, warpForAll: true),
      ).buildMap(wg, servers: [wg]),
    };

    cases.forEach((name, config) {
      test(name, () {
        for (final member in members(config)) {
          expect(
            member['detour'],
            isNot(ConfigBuilder.directTag),
            reason: '${member['tag']} would refuse to dial',
          );
        }
      });
    });

    // The case the first fix missed, and the reason the tunnel stayed broken after
    // it: an imported server keeps its sing-box JSON verbatim in the profile, so the
    // bad field outlives the parser that wrote it. Every test above builds from a
    // freshly parsed config, where the problem no longer exists by construction.
    test('a server saved before the fix is repaired on the way in', () {
      final stored = Outbound.fromStorage(const {
        'tag': 'Old WG',
        'type': 'wireguard',
        'json': {
          'type': 'wireguard',
          'tag': 'Old WG',
          'detour': 'direct',
          'mtu': 1408,
          'address': ['10.0.0.2/32'],
          'private_key': 'aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=',
          'peers': [
            {
              'address': 'vpn.example.com',
              'port': 51820,
              'public_key': 'bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI=',
              'allowed_ips': ['0.0.0.0/0', '::/0'],
              'persistent_keepalive_interval': 25,
            },
          ],
        },
      });
      expect(stored.json['detour'], 'direct', reason: 'the fixture must carry the old shape');

      final config = ConfigBuilder(routing: const RoutingSettings())
          .buildMap(stored, servers: [stored]);
      final endpoint = (config['endpoints'] as List).single as Map<String, Object?>;
      expect(endpoint.containsKey('detour'), isFalse);
      // Repaired on the way through, not mutated in place: the profile on disk is
      // still the user's, and rewriting it from a config build would be a surprise.
      expect(stored.json['detour'], 'direct');
    });

    test('a detour to something real is still allowed through', () {
      // The guard above must not be satisfied by dropping every detour: WARP behind
      // the proxy is a second hop people deliberately ask for.
      final chained = members(
        ConfigBuilder(routing: RoutingSettings(warp: account)).buildMap(trojan),
      ).firstWhere((e) => e['tag'] == ConfigBuilder.warpTag);
      expect(chained['detour'], ConfigBuilder.proxyTag);
    });
  });

  // AmneziaWG reshapes the handshake itself. Reading such a config as plain WireGuard
  // produces a server that looks perfectly fine, sits in the selector, and can never
  // connect -- the least diagnosable outcome the app can reach.
  group('AmneziaWG', () {
    const conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=
Address = 10.8.1.2/32
MTU = 1380
Jc = 3
Jmin = 51
Jmax = 109
S1 = 123
S2 = 82
H1 = 410000001-416021364
H4 = 1700000001-2078121096
RandomTrailers = on
DisableCookies = on

[Peer]
PublicKey = bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.53:51820
''';

    test('is carried by the third core, not by sing-box', () {
      final parsed = WireGuardConfig.parse(conf, name: 'AWG')!;
      expect(parsed.isUsable, isTrue);
      expect(parsed.requiresAmnezia, isTrue);
      // Handed over verbatim: the library takes the config file, and translating it
      // twice is one more place for a parameter to go missing.
      expect(parsed.amneziaConf, contains('Jc = 3'));
      expect(parsed.amneziaConf, contains('DisableCookies = on'));
    });

    // sing-box has no field for any of the obfuscation, so this is not one of its
    // endpoints — it is a loopback proxy in front of a tunnel it cannot see.
    test('is not a sing-box endpoint', () {
      expect(WireGuardConfig.parse(conf, name: 'AWG')!.isEndpoint, isFalse);
    });

    test('a vpn:// wrapper is unwrapped rather than refused', () {
      final link = 'vpn://${base64.encode(utf8.encode(conf))}';
      final parsed = WireGuardConfig.parse(link, name: 'AWG')!;
      expect(parsed.type, 'wireguard');
      expect(parsed.server, '203.0.113.53');
      expect(parsed.serverPort, 51820);
      expect(parsed.requiresAmnezia, isTrue);
      // The decoded config, not the wrapper: the wrapper is not what the core reads.
      expect(parsed.amneziaConf, startsWith('[Interface]'));
    });

    test('an ordinary WireGuard config is still ordinary', () {
      final plain = conf
          .split('\n')
          .where(
            (line) =>
                !RegExp(r'^(Jc|Jmin|Jmax|S1|S2|H1|H4|RandomTrailers|DisableCookies)')
                    .hasMatch(line),
          )
          .join('\n');
      final parsed = WireGuardConfig.parse(plain, name: 'WG')!;
      expect(parsed.isUsable, isTrue);
      expect(parsed.unsupported, isEmpty);
    });

    // The Amnezia app writes the server's name as a comment above [Peer], and it is
    // the only name in the file. Without it an import is titled by its address, which
    // is no use at all to someone running three servers on one host.
    test('takes the name the file gives itself', () {
      final named = '# AmneziaWG-example\n$conf';
      expect(WireGuardConfig.parse(named)!.tag, 'AmneziaWG-example');
    });

    test('a name passed in still wins over the file', () {
      final named = '# From the file\n$conf';
      expect(WireGuardConfig.parse(named, name: 'Mine')!.tag, 'Mine');
    });

    test('falls back to the address when the file names nothing', () {
      expect(WireGuardConfig.parse(conf)!.tag, '203.0.113.53');
    });

    test('a comment that is only a hash is not a name', () {
      expect(WireGuardConfig.parse('#\n#   \n$conf')!.tag, '203.0.113.53');
    });

    // Both kinds of server end up with a wireguard-shaped json and the same tag
    // style, so the list has to say which is which.
    test('is named for what it is, not for what sing-box sees', () {
      expect(WireGuardConfig.parse(conf, name: 'AWG')!.displayType, 'amneziawg');
      final plain = conf
          .split('\n')
          .where(
            (line) =>
                !RegExp(r'^(Jc|Jmin|Jmax|S1|S2|H1|H4|RandomTrailers|DisableCookies)')
                    .hasMatch(line),
          )
          .join('\n');
      expect(WireGuardConfig.parse(plain, name: 'WG')!.displayType, 'wireguard');
    });

    // In the generated config it is a plain SOCKS outbound pointed at the port the
    // third core opens, which is exactly how Xray already appears here.
    test('appears as the loopback port its core listens on, with its credentials', () {
      final awg = WireGuardConfig.parse(conf, name: 'AWG')!;
      const loopback = LoopbackAuth(
        xrayPort: 21000,
        amneziaPort: 22000,
        username: 'user',
        password: 'secret',
      );
      final config = ConfigBuilder(routing: const RoutingSettings())
          .buildMap(awg, servers: [awg], loopback: loopback);
      expect(config['endpoints'], anyOf(isNull, isEmpty));

      final outbounds = (config['outbounds'] as List).cast<Map<String, Object?>>();
      final member = outbounds.firstWhere((e) => e['tag'] == 'AWG');
      expect(member['type'], 'socks');
      expect(member['server'], '127.0.0.1');
      expect(member['server_port'], loopback.amneziaPort);
      expect(member['username'], 'user');
      expect(member['password'], 'secret');
    });

    // A dial option on this outbound only ever applied to dialling 127.0.0.1, never
    // to the destination — checked against the real core — so the legacy one that
    // used to sit here did nothing but wait for sing-box to stop accepting it. The
    // third core resolves names itself, inside the tunnel.
    test('carries no dial option that only looks like it resolves the destination', () {
      final awg = WireGuardConfig.parse(conf, name: 'AWG')!;
      final config = ConfigBuilder(routing: const RoutingSettings()).buildMap(awg, servers: [awg]);
      final member = (config['outbounds'] as List).cast<Map<String, Object?>>().firstWhere(
        (e) => e['tag'] == 'AWG',
      );
      expect(member.containsKey('domain_strategy'), isFalse);
      expect(member.containsKey('domain_resolver'), isFalse);
    });

    // Xray resolves for itself and routes on the name, so it must not be given one.
    test('Xray is left to resolve for itself', () {
      final reality = ShareLink.parse(
        'vless://11111111-2222-3333-4444-555555555555@x.example:443'
        '?security=reality&pbk=k&fp=chrome&sni=x.example&mldsa65Verify=abc#Xray',
      );
      if (reality == null || !reality.requiresXray) return;
      final config = ConfigBuilder(routing: const RoutingSettings())
          .buildMap(reality, servers: [reality]);
      final member = (config['outbounds'] as List).cast<Map<String, Object?>>().firstWhere(
        (e) => e['tag'] == 'Xray',
      );
      expect(member.containsKey('domain_strategy'), isFalse);
    });

    // One instance of Xray runs, and one of AmneziaWG, so at most one server of each
    // kind can be in a config. Before this they were only in it when selected, which
    // meant a list of three servers of three kinds could never have more than two of
    // them measured — and when the plain one was in use, only one.
    group('a server for each core', () {
      final awg = WireGuardConfig.parse(conf, name: 'AWG')!;
      final wg = WireGuardConfig.parse(
        conf
            .split('\n')
            .where(
              (line) =>
                  !RegExp(r'^(Jc|Jmin|Jmax|S1|S2|H1|H4|RandomTrailers|DisableCookies)')
                      .hasMatch(line),
            )
            .join('\n'),
        name: 'WG',
      )!;
      final trojan = ShareLink.parse('trojan://pw@t.example:443#Trojan')!;

      List<Object?> membersWith(Outbound selected, List<Outbound> servers) {
        final config = ConfigBuilder(routing: const RoutingSettings())
            .buildMap(selected, servers: servers);
        final outbounds = (config['outbounds'] as List).cast<Map<String, Object?>>();
        final urltest = outbounds.firstWhere((e) => e['type'] == 'urltest', orElse: () => const {});
        return (urltest['outbounds'] as List?) ?? const [];
      }

      test('every kind is present whichever one is selected', () {
        for (final selected in [awg, wg, trojan]) {
          expect(
            membersWith(selected, [awg, trojan, wg]),
            containsAll(['AWG', 'Trojan', 'WG']),
            reason: 'with ${selected.tag} selected',
          );
        }
      });

      // The second of a kind still cannot be carried, and saying otherwise would put a
      // tag in the config with nothing behind it.
      test('only one server of a kind, and the selected one wins', () {
        final other = WireGuardConfig.parse(conf, name: 'AWG2')!;
        expect(membersWith(trojan, [awg, other, trojan]), contains('AWG'));
        expect(membersWith(trojan, [awg, other, trojan]), isNot(contains('AWG2')));
        expect(membersWith(other, [awg, other, trojan]), contains('AWG2'));
        expect(membersWith(other, [awg, other, trojan]), isNot(contains('AWG')));
      });

      test('a kind nobody in the list needs is simply absent', () {
        expect(membersWith(trojan, [trojan, wg]), containsAll(['Trojan', 'WG']));
        expect(membersWith(trojan, [trojan, wg]), hasLength(2));
      });
    });
  });
}
