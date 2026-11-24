import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';

void main() {
  final server = ShareLink.parse('ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#s')!;
  final base = ConfigBuilder(routing: RoutingSettings.defaults);

  Map<String, Object?> build(ConfigBuilder builder, [Outbound? only]) =>
      jsonDecode(builder.build(only ?? server, servers: [only ?? server])) as Map<String, Object?>;

  Map<String, Object?> dnsServer(ConfigBuilder builder, String tag) {
    final servers = (build(builder)['dns'] as Map)['servers'] as List;
    return (servers.firstWhere((s) => (s as Map)['tag'] == tag) as Map).cast<String, Object?>();
  }

  String strategy(ConfigBuilder builder) => ((build(builder)['dns'] as Map)['strategy']) as String;

  group('direct resolver', () {
    test('empty means the network\'s own resolver', () {
      expect(dnsServer(base, ConfigBuilder.dnsDirectTag)['type'], 'local');
    });

    test('an IP address is used as given', () {
      final entry = dnsServer(base.copyWith(directDns: '9.9.9.9'), ConfigBuilder.dnsDirectTag);
      expect(entry['type'], 'udp');
      expect(entry['server'], '9.9.9.9');
    });

    test('a hostname falls back rather than producing a config that cannot start', () {
      // sing-box refuses this outright -- "missing domain resolver for domain server
      // address" -- because this resolver is the one that resolves hostnames. The UI
      // will not save one; a restored backup still can.
      final entry = dnsServer(
        base.copyWith(directDns: 'https://dns.google/dns-query'),
        ConfigBuilder.dnsDirectTag,
      );
      expect(entry['type'], 'local');
    });

    test('an IP literal is told apart from a hostname', () {
      expect(ConfigBuilder.isIpLiteral('1.1.1.1'), isTrue);
      expect(ConfigBuilder.isIpLiteral('2606:4700:4700::1111'), isTrue);
      expect(ConfigBuilder.isIpLiteral('[2606:4700:4700::1111]'), isTrue);
      expect(ConfigBuilder.isIpLiteral('dns.google'), isFalse);
      expect(ConfigBuilder.isIpLiteral(''), isFalse);
    });
  });

  group('remote resolver', () {
    test('the scheme decides the transport', () {
      for (final (url, type) in [
        ('1.1.1.1', 'udp'),
        ('tls://1.1.1.1', 'tls'),
        ('https://dns.google/dns-query', 'https'),
        ('quic://dns.adguard.com', 'quic'),
        ('h3://cloudflare-dns.com', 'h3'),
        ('tcp://9.9.9.9', 'tcp'),
      ]) {
        expect(
          dnsServer(base.copyWith(remoteDns: url), ConfigBuilder.dnsRemoteTag)['type'],
          type,
          reason: url,
        );
      }
    });

    test('an unknown scheme becomes UDP rather than reaching the core', () {
      // sing-box refuses a type it does not know, which would read to the user as
      // the tunnel breaking for no visible reason.
      expect(
        dnsServer(base.copyWith(remoteDns: 'gopher://1.1.1.1'), ConfigBuilder.dnsRemoteTag)['type'],
        'udp',
      );
    });

    test('it still goes through the proxy', () {
      expect(dnsServer(base, ConfigBuilder.dnsRemoteTag)['detour'], ConfigBuilder.proxyTag);
    });
  });

  group('domain strategy', () {
    test('auto follows the IPv6 setting', () {
      expect(strategy(base), 'ipv4_only');
      expect(strategy(base.copyWith(enableIpv6: true)), 'prefer_ipv4');
    });

    test('an explicit choice wins over the IPv6 setting', () {
      expect(strategy(base.copyWith(domainStrategy: 'ipv6_only', enableIpv6: false)), 'ipv6_only');
    });

    test('every offered value is one sing-box accepts', () {
      // The picker offers these verbatim; a value the core rejects would stop the
      // tunnel starting with nothing pointing back at this screen.
      const accepted = {'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'};
      for (final value in ConfigBuilder.domainStrategies) {
        if (value == ConfigBuilder.strategyAuto) continue;
        expect(accepted, contains(value));
      }
    });
  });

  group('TUN stack', () {
    test('the chosen stack reaches the inbound', () {
      for (final stack in ConfigBuilder.tunStacks) {
        final inbound = ((build(base.copyWith(tunStack: stack))['inbounds'] as List).first as Map);
        expect(inbound['stack'], stack);
      }
    });
  });

  group('settings round-trip', () {
    test('the new options survive being saved and read back', () {
      // They are in the config, so losing one on restart means the tunnel quietly
      // goes back to defaults the user did not choose.
      final configured = base.copyWith(
        directDns: '9.9.9.9',
        domainStrategy: 'prefer_ipv6',
        tunStack: 'gvisor',
        logLevel: 'debug',
        mtu: 1500,
      );
      final restored = ConfigBuilder.fromJson(
        jsonDecode(jsonEncode(configured.toJson())) as Map<String, Object?>,
      );
      expect(restored.directDns, '9.9.9.9');
      expect(restored.domainStrategy, 'prefer_ipv6');
      expect(restored.tunStack, 'gvisor');
      expect(restored.logLevel, 'debug');
      expect(restored.mtu, 1500);
    });

    test('a profile written before these existed keeps working', () {
      final old = ConfigBuilder.fromJson({'routingMode': 'bypassLan', 'mtu': 9000});
      expect(old.directDns, isEmpty);
      expect(old.domainStrategy, ConfigBuilder.strategyAuto);
      expect(old.tunStack, 'mixed');
    });
  });
}
