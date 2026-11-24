import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';

/// What other apps on the device — and, when shared, other devices — can reach.
///
/// Every app on a phone can reach loopback, including the ones the user excluded
/// from the VPN. Anything listening there, or any bypass the VPN grants, is a way to
/// use the tunnel unasked or to learn the address behind it.
void main() {
  final server = ShareLink.parse('ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#s')!;
  final base = ConfigBuilder(routing: RoutingSettings.defaults);

  Map<String, Object?> build(ConfigBuilder builder) => builder.buildMap(server, servers: [server]);

  Map<String, Object?> tun(ConfigBuilder builder) => ((build(builder)['inbounds'] as List)
      .cast<Map<String, Object?>>()
      .firstWhere((i) => i['type'] == 'tun'));

  List<Map<String, Object?>> proxies(ConfigBuilder builder) => (build(builder)['inbounds'] as List)
      .cast<Map<String, Object?>>()
      .where((i) => i['type'] == 'mixed')
      .toList();

  /// Settings as an older version of the app saved them: no version field.
  Map<String, Object?> version1(Map<String, Object?> overrides) =>
      {...base.toJson(), ...overrides}..remove('settingsVersion');

  group('strict route', () {
    test('is on for a new install', () {
      expect(base.strictRoute, isTrue);
      expect(tun(base)['strict_route'], isTrue);
    });

    test('is moved on once for settings saved before it was the default', () {
      final upgraded = ConfigBuilder.fromJson(version1({'strictRoute': false}));
      expect(upgraded.strictRoute, isTrue);
    });

    test('is a choice from then on', () {
      final chosen = ConfigBuilder.fromJson(base.copyWith(strictRoute: false).toJson());
      expect(chosen.strictRoute, isFalse);
    });
  });

  group('local proxies', () {
    final locked = base.copyWith(mixedPort: 2080, directPort: 2081).withProxyCredentials();

    test('demand a login by default', () {
      expect(locked.localProxyLocked, isTrue);
      for (final proxy in proxies(locked)) {
        expect(proxy['listen'], '127.0.0.1');
        expect(proxy['users'], [
          {'username': locked.localProxyUsername, 'password': locked.localProxyPassword},
        ]);
      }
      expect(proxies(locked), hasLength(2));
    });

    test('keep the same login across saves', () {
      expect(identical(locked.withProxyCredentials(), locked), isTrue);
      final reloaded = ConfigBuilder.fromJson(locked.toJson());
      expect(reloaded.localProxyUsername, locked.localProxyUsername);
      expect(reloaded.localProxyPassword, locked.localProxyPassword);
      expect(reloaded.localProxyPassword, hasLength(20));
    });

    test('shared on the network, still demand it', () {
      for (final proxy in proxies(locked.copyWith(shareInLocalNetwork: true))) {
        expect(proxy['listen'], '0.0.0.0');
        expect(proxy['users'], isNotEmpty);
      }
    });

    // A login was asked for and there is nothing to check it against. Coming up open
    // would be the one outcome worse than not coming up.
    test('are not opened at all when the login they need is missing', () {
      expect(proxies(base.copyWith(mixedPort: 2080)), isEmpty);
    });

    test('are open only when the login is switched off', () {
      final open = base.copyWith(mixedPort: 2080, localProxyAuth: false);
      expect(proxies(open).single.containsKey('users'), isFalse);
    });

    test('a proxy already open before this version stays open', () {
      final upgraded = ConfigBuilder.fromJson(version1({'mixedPort': 2080}));
      expect(upgraded.localProxyAuth, isFalse);
      expect(proxies(upgraded).single.containsKey('users'), isFalse);
    });

    test('settings that had no proxy get the login when one is opened', () {
      final upgraded = ConfigBuilder.fromJson(version1({}));
      expect(upgraded.localProxyAuth, isTrue);
    });

    // Android's proxy setting has no field for a login, so handing it a locked proxy
    // would break every app that honours it.
    test('a locked proxy is not handed to Android', () {
      final viaAndroid = locked.copyWith(httpProxyForVpn: true);
      expect(viaAndroid.handsProxyToAndroid, isFalse);
      expect(tun(viaAndroid).containsKey('platform'), isFalse);

      final open = viaAndroid.copyWith(localProxyAuth: false);
      expect(open.handsProxyToAndroid, isTrue);
      expect(((tun(open)['platform'] as Map)['http_proxy'] as Map)['server_port'], 2080);
    });
  });
}
