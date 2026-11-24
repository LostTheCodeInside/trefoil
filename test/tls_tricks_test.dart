import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/xray_config.dart';

void main() {
  // A post-quantum REALITY link: exactly the case that runs on Xray at all.
  const link =
      'vless://11111111-2222-3333-4444-555555555555@example.com:443'
      '?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome'
      '&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&sid=0123abcd'
      '&pqv=zzzz#pq';

  Map<String, Object?> build({TlsTricks tricks = const TlsTricks()}) =>
      jsonDecode(XrayConfig.build(ShareLink.parse(link)!, tricks: tricks)!) as Map<String, Object?>;

  test('off, the config carries no fragmenting dialer at all', () {
    final outbounds = build()['outbounds'] as List;
    expect(outbounds, hasLength(1));
    expect((outbounds.first as Map)['streamSettings'], isNot(contains('sockopt')));
  });

  test('on, the proxy dials through the fragment outbound', () {
    final config = build(tricks: const TlsTricks(fragment: true, length: '5-15'));
    final outbounds = (config['outbounds'] as List).cast<Map<String, Object?>>();
    expect(outbounds, hasLength(2));

    final proxy = outbounds.firstWhere((o) => o['tag'] == 'proxy');
    final stream = proxy['streamSettings']! as Map;
    // Without this the freedom outbound below is never reached and the setting is
    // silently inert.
    expect((stream['sockopt']! as Map)['dialerProxy'], XrayConfig.fragmentTag);

    final fragment = outbounds.firstWhere((o) => o['tag'] == XrayConfig.fragmentTag);
    expect(fragment['protocol'], 'freedom');
    expect((fragment['settings']! as Map)['fragment'], {
      'packets': 'tlshello',
      'length': '5-15',
      'interval': '10-20',
    });
  });

  test('the post-quantum key survives, which is why Xray is here', () {
    final config = build(tricks: const TlsTricks(fragment: true));
    final proxy = (config['outbounds'] as List).first as Map;
    final reality = (proxy['streamSettings'] as Map)['realitySettings'] as Map;
    expect(reality['mldsa65Verify'], 'zzzz');
  });

  group('range validation', () {
    test('accepts the shapes Xray accepts', () {
      for (final value in ['10-30', '0-1', '5', '100-100']) {
        expect(TlsTricks.isValidRange(value), isTrue, reason: value);
      }
    });

    test('rejects what would stop the tunnel starting', () {
      // Xray refuses these at start, and the failure surfaces as a tunnel that
      // never comes up rather than as anything pointing at this setting.
      for (final value in ['', '30-10', 'a-b', '1-2-3', '-5', '1,2']) {
        expect(TlsTricks.isValidRange(value), isFalse, reason: '"$value"');
      }
    });
  });

  test('the settings round-trip', () {
    const tricks = TlsTricks(fragment: true, packets: '1-3', length: '5-15', interval: '2-8');
    final restored = TlsTricks.fromJson(
      jsonDecode(jsonEncode(tricks.toJson())) as Map<String, Object?>,
    );
    expect(restored.fragment, isTrue);
    expect(restored.packets, '1-3');
    expect(restored.length, '5-15');
    expect(restored.interval, '2-8');
  });
}
