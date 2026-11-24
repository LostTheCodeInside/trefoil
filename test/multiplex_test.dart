import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/multiplex.dart';
import 'package:trefoil/core/profile/share_link.dart';

/// Which outbounds carry a `multiplex` block was taken from sing-box v1.13.19's own
/// option structs: only shadowsocks, trojan, vmess and vless embed
/// OutboundMultiplexOptions. Adding one anywhere else produces a config the core
/// refuses to parse, so this is the test that should fail first if that changes.
void main() {
  Map<String, Object?> outboundFor(String link, {MultiplexSettings? mux}) {
    final server = ShareLink.parse(link)!;
    final config = ConfigBuilder(multiplex: mux ?? const MultiplexSettings(enabled: true))
        .buildMap(server, servers: [server]);
    return (config['outbounds'] as List).cast<Map<String, Object?>>().firstWhere(
      (e) => e['tag'] == server.tag,
    );
  }

  group('where multiplex is applied', () {
    test('the four protocols that support it', () {
      expect(outboundFor('trojan://pw@a.example:443#A')['multiplex'], isNotNull);
      expect(outboundFor('ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#A')['multiplex'], isNotNull);
      expect(
        outboundFor('vless://11111111-2222-3333-4444-555555555555@a.example:443#A')['multiplex'],
        isNotNull,
      );
    });

    test('never on the QUIC protocols, which multiplex on their own', () {
      expect(outboundFor('hysteria2://pw@h.example:443#A')['multiplex'], isNull);
      expect(
        outboundFor('tuic://11111111-2222-3333-4444-555555555555:pw@t.example:443#A')['multiplex'],
        isNull,
      );
      expect(outboundFor('anytls://pw@a.example:443#A')['multiplex'], isNull);
    });

    test('never on socks, which has no such field', () {
      expect(outboundFor('socks://dTpw@10.0.0.9:1080#A')['multiplex'], isNull);
    });

    test('never on VLESS with a flow, because Vision splices the raw connection', () {
      final withFlow = outboundFor(
        'vless://11111111-2222-3333-4444-555555555555@a.example:443'
        '?flow=xtls-rprx-vision&security=tls#A',
      );
      expect(withFlow['flow'], 'xtls-rprx-vision');
      expect(withFlow['multiplex'], isNull);
    });

    test('nothing at all while it is off, which is the default', () {
      final off = outboundFor('trojan://pw@a.example:443#A', mux: const MultiplexSettings());
      expect(off['multiplex'], isNull);
      expect(const MultiplexSettings().enabled, isFalse);
    });
  });

  group('the block itself', () {
    test('carries the protocol and stream count sing-box expects', () {
      final block =
          outboundFor(
                'trojan://pw@a.example:443#A',
                mux: const MultiplexSettings(
                  enabled: true,
                  protocol: MultiplexSettings.yamux,
                  maxStreams: 16,
                ),
              )['multiplex']
              as Map;
      expect(block['enabled'], isTrue);
      expect(block['protocol'], 'yamux');
      expect(block['max_streams'], 16);
      // max_connections and min_streams conflict with max_streams in sing-box, so
      // offering all three would let the UI build a config the core rejects.
      expect(block.containsKey('max_connections'), isFalse);
      expect(block.containsKey('min_streams'), isFalse);
    });

    test('padding is absent rather than false when it is off', () {
      final block = outboundFor('trojan://pw@a.example:443#A')['multiplex'] as Map;
      expect(block.containsKey('padding'), isFalse);
    });
  });

  group('stored settings', () {
    test('round-trip', () {
      const original = MultiplexSettings(
        enabled: true,
        protocol: MultiplexSettings.smux,
        maxStreams: 32,
        padding: true,
      );
      final restored = MultiplexSettings.fromJson(original.toJson());
      expect(restored.enabled, isTrue);
      expect(restored.protocol, 'smux');
      expect(restored.maxStreams, 32);
      expect(restored.padding, isTrue);
    });

    test('a profile written before mux existed reads back as off', () {
      final settings = ConfigBuilder.fromJson(const ConfigBuilder().toJson()..remove('multiplex'));
      expect(settings.multiplex.enabled, isFalse);
    });

    test('a value from outside the app cannot produce a config the core rejects', () {
      final absurd = MultiplexSettings.fromJson({
        'enabled': true,
        'protocol': 'not-a-protocol',
        'maxStreams': 99999,
      });
      expect(absurd.protocol, MultiplexSettings.h2mux);
      expect(absurd.maxStreams, MultiplexSettings.maxAllowedStreams);

      final negative = MultiplexSettings.fromJson({'maxStreams': -5});
      expect(negative.maxStreams, MultiplexSettings.minStreams);
    });

    test('the whole settings object round-trips it', () {
      const builder = ConfigBuilder(
        multiplex: MultiplexSettings(enabled: true, protocol: MultiplexSettings.smux),
      );
      expect(ConfigBuilder.fromJson(builder.toJson()).multiplex.protocol, 'smux');
      expect(ConfigBuilder.fromJson(builder.toJson()).multiplex.enabled, isTrue);
    });
  });
}
