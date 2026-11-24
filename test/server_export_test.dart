import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/server_export.dart';
import 'package:trefoil/core/profile/share_link.dart';

void main() {
  final vless = ShareLink.parse(
    'vless://11111111-2222-3333-4444-555555555555@a.example:443'
    '?type=ws&security=tls&sni=a.example&path=%2Fws#One',
  )!;
  final trojan = ShareLink.parse('trojan://pw@b.example:443#Two')!;
  final ss = ShareLink.parse('ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@c.example:8388#Three')!;

  group('exporting servers', () {
    test('writes the links, newline separated, base64 over the whole thing', () {
      final export = ServerExport.of([vless, trojan, ss]);
      expect(export.exported, 3);
      expect(export.skipped, 0);

      final decoded = utf8.decode(base64.decode(export.body));
      expect(const LineSplitter().convert(decoded), hasLength(3));
      expect(decoded, contains('vless://'));
      expect(decoded, contains('trojan://'));
      expect(decoded, contains('ss://'));
    });

    // The point of the format. Anything else would be a shape only this app reads,
    // which is the situation the feature exists to end.
    test('what comes out goes back in', () {
      final export = ServerExport.of([vless, trojan, ss]);
      final reimported = ShareLink.parseSubscription(export.body);

      expect(reimported.map((e) => e.tag), ['One', 'Two', 'Three']);
      expect(reimported.map((e) => e.type), [vless.type, trojan.type, ss.type]);
      expect(reimported.map((e) => e.server), ['a.example', 'b.example', 'c.example']);
      expect(reimported.map((e) => e.serverPort), [443, 443, 8388]);
    });

    // A custom outbound pasted as raw JSON never had a link, and neither did anything
    // saved before the app started keeping them. Exporting a shorter list than the one
    // on screen without saying so is how servers vanish on the next phone.
    test('counts what it could not write down', () {
      final custom = Outbound(
        tag: 'Hand written',
        type: 'vmess',
        json: const {'type': 'vmess', 'tag': 'Hand written'},
      );
      final blank = vless.withTag('Blank');
      final export = ServerExport.of([
        vless,
        custom,
        Outbound(tag: blank.tag, type: blank.type, json: blank.json, link: '   '),
      ]);

      expect(export.exported, 1);
      expect(export.skipped, 2);
      expect(ShareLink.parseSubscription(export.body), hasLength(1));
    });

    test('an empty list is empty rather than a base64 of nothing', () {
      final export = ServerExport.of(const []);
      expect(export.isEmpty, isTrue);
      expect(export.exported, 0);
      expect(export.skipped, 0);
      expect(export.body, isEmpty);
    });

    test('one server is still a list', () {
      final export = ServerExport.of([trojan]);
      expect(export.isEmpty, isFalse);
      expect(ShareLink.parseSubscription(export.body).single.tag, 'Two');
    });
  });
}
