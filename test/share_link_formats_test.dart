import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/server_check.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/xray_config.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

/// The corners of share links that clients actually write and that were read wrong:
/// a server that imports without complaint and never answers.
void main() {
  group('a plus in a link', () {
    // Form decoding turns it into a space, and a key with a space in it is another key.
    test('stays a plus in a key', () {
      final out = ShareLink.parse(
        'wireguard://aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI%3D@192.0.2.1:51820'
        '?publickey=AAAA+AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=&address=10.0.0.2/32#W',
      )!;
      final peer = (out.json['peers'] as List).single as Map;
      expect(peer['public_key'], 'AAAA+AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
    });

    test('stays a plus in an encoded one too', () {
      expect(ShareLink.query(Uri.parse('vless://a@b:1?x=1%2B2&y=3+4&z')), {
        'x': '1+2',
        'y': '3+4',
        'z': '',
      });
    });

    test('a REALITY key in standard base64 is put in the alphabet the core reads', () {
      final out = ShareLink.parse(
        'vless://$_uuid@192.0.2.1:443?security=reality&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI+T4E7RoLJS0=#R',
      )!;
      expect(
        ((out.json['tls'] as Map)['reality'] as Map)['public_key'],
        'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
      );
      expect(out.isUsable, isTrue);
    });
  });

  group('shadowsocks', () {
    test('a key written out with percent-encoding', () {
      final out = ShareLink.parse(
        'ss://2022-blake3-aes-128-gcm:AAAAAAAAAAAAAAAAAAAAAA%3D%3D@192.0.2.1:8388#S',
      )!;
      expect(out.json['method'], '2022-blake3-aes-128-gcm');
      expect(out.json['password'], 'AAAAAAAAAAAAAAAAAAAAAA==');
    });

    test('a slash before the query is not part of the port', () {
      final out = ShareLink.parse(
        'ss://YWVzLTEyOC1nY206cHc@192.0.2.1:8388/?plugin=obfs-local%3Bobfs%3Dhttp'
        '%3Bobfs-host%3Da.example#S',
      )!;
      expect(out.json['server_port'], 8388);
      expect(out.json['plugin'], 'obfs-local');
      expect(out.json['plugin_opts'], 'obfs=http;obfs-host=a.example');
    });

    // Connecting without the plugin is a server that refuses every byte.
    test('a plugin no core has is named, not dropped', () {
      final out = ShareLink.parse(
        'ss://YWVzLTEyOC1nY206cHc@192.0.2.1:8388?plugin=kcptun%3Bmode%3Dfast#S',
      )!;
      expect(out.problem?.code, ServerProblem.plugin);
      expect(out.problem?.detail, 'kcptun');
    });
  });

  group('hysteria', () {
    test('2: a list of ports is hopped between', () {
      final out = ShareLink.parse('hysteria2://pw@192.0.2.1:443,5000-6000/?sni=a.example#H')!;
      expect(out.json['server_port'], 443);
      expect(out.json['server_ports'], ['443:443', '5000:6000']);
      expect(out.isUsable, isTrue);
    });

    test('2: the same through mport', () {
      final out = ShareLink.parse('hy2://pw@192.0.2.1:443?mport=20000-30000#H')!;
      expect(out.json['server_ports'], ['20000:30000']);
    });

    // One range the core cannot read fails the whole config.
    test('2: what is not a port is left out of the list', () {
      expect(ShareLink.portRanges('443, 70000, 9-5, x, 8000-9000'), ['443:443', '8000:9000']);
      expect(ShareLink.portRanges(''), isEmpty);
    });

    test('2: obfs=none is no obfuscation', () {
      final out = ShareLink.parse('hysteria2://pw@192.0.2.1:443?obfs=none#H')!;
      expect(out.json.containsKey('obfs'), isFalse);
    });

    test('1: the password is in obfsParam, and the method is not it', () {
      final out = ShareLink.parse(
        'hysteria://192.0.2.1:443?auth=a&obfs=xplus&obfsParam=secret&upmbps=10&downmbps=50#H',
      )!;
      expect(out.json['obfs'], 'secret');
    });

    test('1: a protocol that is not UDP is refused by name', () {
      final out = ShareLink.parse(
        'hysteria://192.0.2.1:443?auth=a&protocol=faketcp&upmbps=10&downmbps=50#H',
      )!;
      expect(out.problem?.code, ServerProblem.transport);
      expect(out.problem?.detail, 'faketcp');
    });
  });

  group('transports', () {
    // Imported as plain TCP, they looked fine and never answered.
    test('mKCP and the like are refused rather than read as TCP', () {
      final out = ShareLink.parse('vless://$_uuid@192.0.2.1:443?type=kcp&security=none#K')!;
      expect(out.problem?.code, ServerProblem.transport);
      expect(out.problem?.detail, 'kcp');
    });

    test('TCP with an HTTP header', () {
      final link = base64.encode(
        utf8.encode(
          jsonEncode({
            'v': '2',
            'ps': 'V',
            'add': '192.0.2.1',
            'port': '80',
            'id': _uuid,
            'net': 'tcp',
            'type': 'http',
            'host': 'a.example,b.example',
            'path': '/x',
          }),
        ),
      );
      final out = ShareLink.parse('vmess://$link')!;
      expect(out.json['transport'], {
        'type': 'http',
        'host': ['a.example', 'b.example'],
        'path': '/x',
        'method': 'GET',
      });
      expect(out.isUsable, isTrue);
    });
  });

  group('for Xray', () {
    test('XHTTP, with its settings', () {
      final extra = Uri.encodeQueryComponent('{"xPaddingBytes": "100-1000"}');
      final out = ShareLink.parse(
        'vless://$_uuid@192.0.2.1:443?type=xhttp&security=tls&sni=a.example&path=%2Fx'
        '&mode=packet-up&extra=$extra#X',
      )!;
      expect(out.requiresXray, isTrue);
      expect(out.isUsable, isTrue);
      final stream = _stream(XrayConfig.build(out)!);
      expect(stream['network'], 'xhttp');
      expect(stream['xhttpSettings'], {
        'path': '/x',
        'mode': 'packet-up',
        'extra': {'xPaddingBytes': '100-1000'},
      });
    });

    test('VLESS encryption is carried as written', () {
      final out = ShareLink.parse(
        'vless://$_uuid@192.0.2.1:443?encryption=mlkem768x25519plus.native.0rtt.abc'
        '&security=none#E',
      )!;
      expect(out.requiresXray, isTrue);
      final vnext =
          ((((jsonDecode(XrayConfig.build(out)!) as Map)['outbounds'] as List).first
                      as Map)['settings']
                  as Map)['vnext']
              as List;
      expect(
        (((vnext.single as Map)['users'] as List).single as Map)['encryption'],
        'mlkem768x25519plus.native.0rtt.abc',
      );
    });

    // Xray refuses the whole config over it, so the server is named instead of the
    // tunnel failing to start.
    test('skipping certificate checks is refused unless a certificate is named', () {
      const link = 'vless://$_uuid@192.0.2.1:443?type=xhttp&security=tls&allowInsecure=1';
      expect(ShareLink.parse('$link#I')!.problem?.code, ServerProblem.insecureTls);
      final pinned = ShareLink.parse('$link&pcs=ab12#I')!;
      expect(pinned.isUsable, isTrue);
      final tls = _stream(XrayConfig.build(pinned)!)['tlsSettings'] as Map;
      expect(tls['pinnedPeerCertSha256'], 'ab12');
      expect(tls.containsKey('allowInsecure'), isFalse);
    });
  });
}

Map<String, Object?> _stream(String config) =>
    (((jsonDecode(config) as Map)['outbounds'] as List).first as Map)['streamSettings']
        as Map<String, Object?>;
