import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/clash_config.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/share_link.dart';

/// Clash/Meta subscriptions, which a good number of providers ship instead of a
/// list of share links. Every expected shape here was checked against the real
/// sing-box binary (`sing-box check`) for v1.13.19.
const _document = '''
proxies:
  - {name: "flow style", type: ss, server: 1.2.3.4, port: 8388, cipher: chacha20-ietf-poly1305, password: "pw"}
  - name: "block style"
    type: vmess
    server: v.example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    alterId: 4
    tls: true
    servername: sni.example
    network: ws
    ws-opts:
      path: /path
      headers:
        Host: host.example
  - name: "reality"
    type: vless
    server: r.example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    flow: xtls-rprx-vision
    client-fingerprint: firefox
    servername: www.microsoft.com
    reality-opts:
      public-key: pubkey
      short-id: 0123abcd
  - {name: "unknown type", type: ssr, server: s.example, port: 443, cipher: aes-256-cfb, password: pw}
  - {name: "tuic v4", type: tuic, server: t4.example, port: 443, token: sometoken}
  - {name: "no server", type: ss, port: 8388, cipher: aes-256-gcm, password: pw}
''';

void main() {
  _clashHysteriaBandwidth();
  group('ClashConfig.looksLikeClash', () {
    test('recognises a proxies document', () {
      expect(ClashConfig.looksLikeClash(_document), isTrue);
      expect(ClashConfig.looksLikeClash('  proxies:\n  - {}'), isTrue);
    });

    test('does not claim a list of share links', () {
      expect(
        ClashConfig.looksLikeClash('vless://uuid@example.com:443#A\ntrojan://pw@b.example:443'),
        isFalse,
      );
      expect(ClashConfig.looksLikeClash(''), isFalse);
      // The word alone is not enough; it has to be a key.
      expect(ClashConfig.looksLikeClash('these are my proxies'), isFalse);
    });
  });

  group('ClashConfig.parse', () {
    final parsed = ClashConfig.parse(_document);

    test('reads both flow and block style, and skips what it cannot run', () {
      // ssr has no sing-box outbound, TUIC v4 authenticates with a token that
      // sing-box's v5-only implementation cannot use, and one entry has no server.
      expect(parsed.map((e) => e.tag), ['flow style', 'block style', 'reality']);
    });

    test('shadowsocks keeps its cipher and password', () {
      final ss = parsed.firstWhere((e) => e.tag == 'flow style');
      expect(ss.type, 'shadowsocks');
      expect(ss.json['server'], '1.2.3.4');
      expect(ss.json['server_port'], 8388);
      expect(ss.json['method'], 'chacha20-ietf-poly1305');
      expect(ss.json['password'], 'pw');
    });

    test('vmess carries its transport and TLS across', () {
      final vmess = parsed.firstWhere((e) => e.tag == 'block style');
      expect(vmess.type, 'vmess');
      expect(vmess.json['alter_id'], 4);
      expect(vmess.json['security'], 'auto');
      final transport = vmess.json['transport'] as Map;
      expect(transport['type'], 'ws');
      expect(transport['path'], '/path');
      expect((transport['headers'] as Map)['Host'], 'host.example');
      expect((vmess.json['tls'] as Map)['server_name'], 'sni.example');
    });

    test('vless picks up REALITY even without an explicit tls flag', () {
      final vless = parsed.firstWhere((e) => e.tag == 'reality');
      expect(vless.json['flow'], 'xtls-rprx-vision');
      final tls = vless.json['tls'] as Map;
      expect(tls['server_name'], 'www.microsoft.com');
      expect((tls['reality'] as Map)['public_key'], 'pubkey');
      expect((tls['reality'] as Map)['short_id'], '0123abcd');
      // The document's own fingerprint, not the fallback.
      expect((tls['utls'] as Map)['fingerprint'], 'firefox');
    });

    test('a document that is not YAML at all yields nothing rather than throwing', () {
      expect(ClashConfig.parse('{{{ not yaml'), isEmpty);
      expect(ClashConfig.parse('proxies: "a string, not a list"'), isEmpty);
    });

    test('bandwidth is read from either a number or a "30 Mbps" string', () {
      final hysteria = ClashConfig.parse('''
proxies:
  - {name: a, type: hysteria2, server: h.example, port: 443, password: pw, up: "30 Mbps", down: 200}
''');
      expect(hysteria.single.json['up_mbps'], 30);
      expect(hysteria.single.json['down_mbps'], 200);
    });

    test('a shadowsocks plugin becomes sing-box plugin options', () {
      final ss = ClashConfig.parse('''
proxies:
  - name: a
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-gcm
    password: pw
    plugin: obfs
    plugin-opts:
      mode: tls
      host: bing.com
''');
      // Clash's `obfs` is simple-obfs, which sing-box knows as obfs-local.
      expect(ss.single.json['plugin'], 'obfs-local');
      expect(ss.single.json['plugin_opts'], 'mode=tls;host=bing.com');
    });

    test('skip-cert-verify survives, because the document is the user\'s own', () {
      final out = ClashConfig.parse('''
proxies:
  - {name: a, type: trojan, server: t.example, port: 443, password: pw, skip-cert-verify: true}
''');
      expect((out.single.json['tls'] as Map)['insecure'], isTrue);
    });

    test('verification stays on when the document does not ask otherwise', () {
      final out = ClashConfig.parse('''
proxies:
  - {name: a, type: trojan, server: t.example, port: 443, password: pw}
''');
      expect((out.single.json['tls'] as Map).containsKey('insecure'), isFalse);
    });
  });

  group('ShareLink.parseSubscription', () {
    test('routes a Clash document to the Clash parser', () {
      final out = ShareLink.parseSubscription(_document, subscriptionId: 'sub-1');
      expect(out.length, 3);
      expect(out.every((e) => e.subscriptionId == 'sub-1'), isTrue);
    });

    test('unwraps a base64 body before deciding it is Clash', () {
      final wrapped = base64.encode(utf8.encode(_document));
      expect(ShareLink.parseSubscription(wrapped).length, 3);
    });

    test('a link list still parses as one', () {
      final out = ShareLink.parseSubscription(
        'trojan://pw@a.example:443#A\ntrojan://pw@b.example:443#B',
      );
      expect(out.map((e) => e.tag), ['A', 'B']);
    });

    test('repeated names are made unique, whichever format they came from', () {
      final out = ShareLink.parseSubscription('''
proxies:
  - {name: same, type: trojan, server: a.example, port: 443, password: pw}
  - {name: same, type: trojan, server: b.example, port: 443, password: pw}
  - {name: same, type: trojan, server: c.example, port: 443, password: pw}
''');
      // sing-box rejects the whole config over a duplicate tag, not just the entry.
      expect(out.map((e) => e.tag), ['same', 'same (2)', 'same (3)']);
      expect(out.map((e) => e.json['tag']), ['same', 'same (2)', 'same (3)']);
    });
  });
}

/// The same requirement, on the Clash side. One entry without bandwidth would
/// otherwise stop the whole subscription's config from starting.
void _clashHysteriaBandwidth() {
  test('clash hysteria v1 without bandwidth still gets both fields', () {
    final out = ClashConfig.parse('''
proxies:
  - {name: a, type: hysteria, server: h.example, port: 443, auth-str: pw}
''');
    expect(out.single.json['up_mbps'] as int, greaterThan(0));
    expect(out.single.json['down_mbps'] as int, greaterThan(0));
  });

  // sing-box has exactly two SIP003 plugins. An unrecognised name is not a field it
  // ignores -- it is `plugin not found` at start, fatal for the whole config rather
  // than for the one server, so one exotic entry in a long subscription used to leave
  // the tunnel unable to start at all.
  group('plugins', () {
    test('simple-obfs keeps the name sing-box knows it by', () {
      final json = ClashConfig.parse('''
proxies:
  - {name: P, type: ss, server: a.example, port: 8388, cipher: aes-256-gcm, password: pw,
     plugin: obfs, plugin-opts: {mode: tls, host: www.example.com}}
''').single.json;
      expect(json['plugin'], 'obfs-local');
      expect(json['plugin_opts'], contains('mode=tls'));
    });

    test('v2ray-plugin passes through', () {
      final parsed = ClashConfig.parse('''
proxies:
  - {name: P, type: ss, server: a.example, port: 8388, cipher: aes-256-gcm, password: pw,
     plugin: v2ray-plugin}
''').single;
      expect(parsed.json['plugin'], 'v2ray-plugin');
      expect(parsed.isUsable, isTrue);
    });

    test('one nobody can run is unsupported rather than fatal', () {
      final parsed = ClashConfig.parse('''
proxies:
  - {name: P, type: ss, server: a.example, port: 8388, cipher: aes-256-gcm, password: pw,
     plugin: some-plugin-from-a-fork}
''').single;
      expect(parsed.isUsable, isFalse);
      expect(parsed.unsupported.single, contains('some-plugin-from-a-fork'));
      // Parsed rather than dropped: the UI names the missing feature, and the config
      // builder leaves the server out.
      expect(parsed.tag, 'P');
    });
  });

  // Clash writes ShadowTLS as a plugin on one proxy. sing-box has no such plugin: it
  // is two outbounds, the Shadowsocks one dialling through the TLS one.
  group('ShadowTLS', () {
    final parsed = ClashConfig.parse('''
proxies:
  - name: STLS
    type: ss
    server: a.example
    port: 443
    cipher: aes-256-gcm
    password: pw
    plugin: shadow-tls
    plugin-opts:
      host: www.microsoft.com
      password: stlspw
      version: 3
      alpn: [h2]
''').single;

    test('becomes a chain, not a plugin', () {
      expect(parsed.json.containsKey('plugin'), isFalse);
      expect(parsed.chain, hasLength(1));
      expect(parsed.chain.single['type'], 'shadowtls');
      expect(parsed.isUsable, isTrue);
    });

    test('the address moves to the link that actually dials out', () {
      // The Shadowsocks half keeps only its cipher and password.
      expect(parsed.json.containsKey('server'), isFalse);
      expect(parsed.json.containsKey('server_port'), isFalse);
      expect(parsed.chain.single['server'], 'a.example');
      expect(parsed.chain.single['server_port'], 443);
      // And the server list still has something to show for it.
      expect(parsed.server, 'a.example');
      expect(parsed.serverPort, 443);
    });

    test('the impersonated site is a name, not a destination', () {
      final tls = parsed.chain.single['tls'] as Map<String, Object?>;
      expect(tls['server_name'], 'www.microsoft.com');
      expect(tls['alpn'], ['h2']);
      expect(parsed.chain.single['password'], 'stlspw');
      expect(parsed.chain.single['version'], 3);
    });

    test('an absurd version reads as the usual one', () {
      final odd = ClashConfig.parse('''
proxies:
  - {name: S, type: ss, server: a.example, port: 443, cipher: aes-256-gcm, password: pw,
     plugin: shadow-tls, plugin-opts: {version: 9}}
''').single;
      expect(odd.chain.single['version'], 3);
    });

    test('survives a round trip through storage', () {
      final restored = Outbound.fromStorage(parsed.toStorage());
      expect(restored.chain, parsed.chain);
      expect(restored.server, 'a.example');
    });

    // Subscriptions re-tag every server, and that copy used to leave the chain behind.
    test('keeps its chain when it arrives in a subscription', () {
      final fromSub = ShareLink.parseSubscription('''
proxies:
  - {name: STLS, type: ss, server: a.example, port: 443, cipher: aes-256-gcm, password: pw,
     plugin: shadow-tls, plugin-opts: {host: www.microsoft.com, password: stlspw, version: 3}}
''', subscriptionId: 'sub1').single;
      expect(fromSub.chain, hasLength(1));
      expect(fromSub.chain.single['type'], 'shadowtls');
      expect(fromSub.subscriptionId, 'sub1');
    });
  });
}
