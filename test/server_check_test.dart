import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/server_check.dart';
import 'package:trefoil/core/profile/share_link.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';
const _realityKey = 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0';
const _wireGuardKey = 'aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=';

/// What sing-box refuses at start, found before it gets there.
///
/// Each of these takes the whole config down with it, so a subscription with one
/// mistyped server used to be a subscription with none.
void main() {
  Map<String, Object?> vless({Map<String, Object?>? tls, Map<String, Object?>? transport}) => {
    'type': 'vless',
    'server': '192.0.2.1',
    'server_port': 443,
    'uuid': _uuid,
    'tls': ?tls,
    'transport': ?transport,
  };
  Map<String, Object?> shadowsocks(String method, String password, [String? options]) => {
    'type': 'shadowsocks',
    'server': '192.0.2.1',
    'server_port': 8388,
    'method': method,
    'password': password,
    if (options != null) ...{'plugin': 'obfs-local', 'plugin_opts': options},
  };
  Map<String, Object?> reality({String key = _realityKey, String shortId = ''}) => vless(
    tls: {
      'enabled': true,
      'utls': {'enabled': true, 'fingerprint': 'chrome'},
      'reality': {'enabled': true, 'public_key': key, 'short_id': shortId},
    },
  );
  Map<String, Object?> wireGuard({String key = _wireGuardKey, Object? port = 51820}) => {
    'type': 'wireguard',
    'private_key': _wireGuardKey,
    'peers': [
      {'address': '192.0.2.1', 'port': port, 'public_key': key},
    ],
  };

  group('refuses', () {
    final cases = <String, (Map<String, Object?>, String)>{
      'a port past the last one': ({...vless(), 'server_port': 70000}, ServerProblem.port),
      'a vless flow nothing speaks': ({...vless(), 'flow': 'xtls-rprx-direct'}, ServerProblem.flow),
      'a vmess cipher': (
        {'type': 'vmess', 'server_port': 443, 'security': 'aes-256-gcm'},
        ServerProblem.cipher,
      ),
      'a shadowsocks cipher': (shadowsocks('aes-256-gmc', 'pw'), ServerProblem.cipher),
      'a 2022 key of the wrong length': (
        shadowsocks('2022-blake3-aes-256-gcm', 'AAAAAAAAAAAAAAAAAAAAAA=='),
        ServerProblem.key,
      ),
      'a 2022 key that is not base64': (
        shadowsocks('2022-blake3-aes-128-gcm', 'plain password'),
        ServerProblem.key,
      ),
      'an obfs mode': (shadowsocks('aes-128-gcm', 'pw', 'obfs=quic'), ServerProblem.obfs),
      'a tuic congestion control': (
        {'type': 'tuic', 'server_port': 443, 'uuid': _uuid, 'congestion_control': 'reno'},
        ServerProblem.congestion,
      ),
      'a tuic uuid': ({'type': 'tuic', 'server_port': 443, 'uuid': 'me'}, ServerProblem.key),
      'a hysteria2 obfuscation': (
        {
          'type': 'hysteria2',
          'server_port': 443,
          'obfs': {'type': 'xor', 'password': 'pw'},
        },
        ServerProblem.obfs,
      ),
      'a fingerprint uTLS does not have': (
        vless(
          tls: {
            'enabled': true,
            'utls': {'enabled': true, 'fingerprint': 'netscape'},
          },
        ),
        ServerProblem.fingerprint,
      ),
      'a REALITY key': (reality(key: 'PUBKEY'), ServerProblem.key),
      // Not refused by the core at all: longer than eight bytes, it crashes.
      'a REALITY short id': (reality(shortId: '00112233445566778899'), ServerProblem.key),
      'a transport': (vless(transport: {'type': 'kcp'}), ServerProblem.transport),
      'a path that is not one': (
        vless(transport: {'type': 'ws', 'path': '/100%'}),
        ServerProblem.path,
      ),
      'a WireGuard key': (wireGuard(key: 'short'), ServerProblem.key),
      'a WireGuard port': (wireGuard(port: 0), ServerProblem.port),
    };
    for (final MapEntry(key: name, value: (json, code)) in cases.entries) {
      test(name, () => expect(ServerCheck.of(json)?.code, code));
    }
  });

  // Too strict is the worse mistake: it takes away a server that works.
  group('accepts', () {
    final cases = <String, Map<String, Object?>>{
      'plain vless': vless(),
      'a uuid that is any string, as vless allows': {...vless(), 'uuid': 'anything'},
      'REALITY with and without a short id': reality(shortId: '0123456789abcdef'),
      'the empty short id': reality(),
      'a shadowsocks 2022 key with a user key': shadowsocks(
        '2022-blake3-aes-128-gcm',
        'AAAAAAAAAAAAAAAAAAAAAA==:AAAAAAAAAAAAAAAAAAAAAA==',
      ),
      'shadowsocks with no encryption and no password': shadowsocks('none', ''),
      'obfs with its options in either order': shadowsocks(
        'aes-128-gcm',
        'pw',
        'obfs-host=a.example;obfs=tls',
      ),
      'a percent-encoded path': vless(transport: {'type': 'ws', 'path': '/a%20b?ed=2048'}),
      'a hysteria2 server with only a range of ports': {
        'type': 'hysteria2',
        'server_ports': ['5000:6000'],
      },
      'a tuic uuid without dashes': {
        'type': 'tuic',
        'server_port': 443,
        'uuid': _uuid.replaceAll('-', ''),
      },
      'WireGuard': wireGuard(),
      'a type this does not know': {'type': 'ssh', 'server': '192.0.2.1'},
    };
    for (final MapEntry(key: name, value: json) in cases.entries) {
      test(name, () => expect(ServerCheck.of(json), isNull));
    }
  });

  // The check is made on the server rather than stored with it, so a profile saved by
  // a version that did not look is covered as well.
  test('a stored server is checked as it is, not as it was saved', () {
    final stored = Outbound.fromStorage({
      'tag': 'Old',
      'type': 'shadowsocks',
      'json': {...shadowsocks('aes-256-gmc', 'pw'), 'tag': 'Old'},
      'unsupported': const <String>[],
    });
    expect(stored.isUsable, isFalse);
    expect(stored.problem?.detail, 'aes-256-gmc');
  });

  test('a reason saved before there were codes is still readable', () {
    expect(ServerProblem.parse('the shadow-tls plugin').code, ServerProblem.plugin);
    expect(ServerProblem.parse('the shadow-tls plugin').detail, 'shadow-tls');
    expect(ServerProblem.parse('Something said in words').code, '');
    expect(ServerProblem.parse('Something said in words').detail, 'Something said in words');
    expect(ServerProblem.parse('transport:kcp').detail, 'kcp');
  });

  test('one bad server is left out and the rest are kept', () {
    final good = ShareLink.parse('trojan://pw@192.0.2.1:443#Good')!;
    final bad = ShareLink.parse('ss://bm90LWEtY2lwaGVyOnB3@192.0.2.9:8388#Bad')!;
    expect(bad.isUsable, isFalse);
    final config = const ConfigBuilder(routing: RoutingSettings())
        .buildMap(good, servers: [bad, good]);
    final tags = [for (final o in config['outbounds'] as List) (o as Map)['tag']];
    expect(tags, contains('Good'));
    expect(tags, isNot(contains('Bad')));
    // Nor named by anything that is still there.
    expect('$config', isNot(contains('Bad')));
  });

  // It only decides which browser the handshake resembles, so it is no reason to lose
  // the server.
  test('an unknown fingerprint in a link is replaced rather than refused', () {
    final out = ShareLink.parse(
      'vless://$_uuid@192.0.2.1:443?security=tls&sni=a.example&fp=netscape#A',
    )!;
    expect(out.isUsable, isTrue);
    expect(((out.json['tls'] as Map)['utls'] as Map)['fingerprint'], 'chrome');
  });
}
