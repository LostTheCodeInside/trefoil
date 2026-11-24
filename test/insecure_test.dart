import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';

void main() {
  final base = ConfigBuilder(routing: RoutingSettings.defaults);

  List<Map<String, Object?>> outboundsOf(ConfigBuilder builder, String link) {
    final server = ShareLink.parse(link)!;
    final config = jsonDecode(builder.build(server, servers: [server])) as Map<String, Object?>;
    return (config['outbounds'] as List).cast<Map<String, Object?>>();
  }

  Object? insecureOf(ConfigBuilder builder, String link) {
    final withTls = outboundsOf(builder, link).where((o) => o['tls'] != null);
    return withTls.isEmpty ? null : (withTls.first['tls']! as Map)['insecure'];
  }

  const tlsLink = 'trojan://pw@example.com:443?security=tls&sni=a.example.com#t';
  const plainLink = 'ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#ss';

  test('off by default', () {
    expect(base.allowInsecure, isFalse);
    expect(insecureOf(base, tlsLink), isNull);
  });

  test('on, it reaches every outbound that uses TLS', () {
    expect(insecureOf(base.copyWith(allowInsecure: true), tlsLink), isTrue);
  });

  test('it does not invent TLS on an outbound that has none', () {
    // Shadowsocks carries no TLS block; adding the field would be meaningless and
    // sing-box would have to be asked what it means.
    final outbounds = outboundsOf(base.copyWith(allowInsecure: true), plainLink);
    expect(outbounds.every((o) => o['tls'] == null || o['type'] != 'shadowsocks'), isTrue);
  });

  test('a link that asked for it keeps working with the setting off', () {
    // Per-server is the narrow case and predates this; the global switch must not be
    // what makes it work.
    const asked = 'trojan://pw@example.com:443?security=tls&sni=a.com&allowInsecure=1#t';
    expect(insecureOf(base, asked), isTrue);
  });

  test('the setting survives a round-trip', () {
    final restored = ConfigBuilder.fromJson(
      jsonDecode(jsonEncode(base.copyWith(allowInsecure: true).toJson())) as Map<String, Object?>,
    );
    expect(restored.allowInsecure, isTrue);
  });

  test('a profile written before it existed defaults to verifying', () {
    // The dangerous direction must never be what an upgrade silently picks.
    expect(ConfigBuilder.fromJson({'mtu': 9000}).allowInsecure, isFalse);
  });
}
