import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/server_usage.dart';

void main() {
  // Written by the Android service, read here. Another process's file is not a
  // contract to be trusted: one entry that is not what we expect must not cost the
  // rest of them.
  group('reading the per-server totals', () {
    test('keeps a tag with traffic against it', () {
      final usage = ServerUsageStore.parse(
        jsonDecode('''
        {"Home": {"up": 1024, "down": 4096}}
      '''),
      );
      expect(usage['Home']!.upload, 1024);
      expect(usage['Home']!.download, 4096);
      expect(usage['Home']!.total, 5120);
    });

    test('leaves out a server that has carried nothing', () {
      // Not an error, just nothing to say: the row shows no figure rather than a
      // zero, which reads as a measurement.
      expect(ServerUsageStore.parse(jsonDecode('{"Idle": {"up": 0, "down": 0}}')), isEmpty);
    });

    test('a missing half counts as zero rather than losing the entry', () {
      final usage = ServerUsageStore.parse(jsonDecode('{"Half": {"down": 700}}'));
      expect(usage['Half']!.upload, 0);
      expect(usage['Half']!.download, 700);
    });

    test('one unusable entry does not cost the others', () {
      final usage = ServerUsageStore.parse(
        jsonDecode('''
        {"Good": {"up": 1, "down": 2}, "Bad": "not an object", "": {"up": 5, "down": 5}}
      '''),
      );
      expect(usage.keys, ['Good']);
    });

    test('anything that is not a map at all reads as nothing recorded', () {
      expect(ServerUsageStore.parse(jsonDecode('[]')), isEmpty);
      expect(ServerUsageStore.parse(jsonDecode('"nonsense"')), isEmpty);
      expect(ServerUsageStore.parse(null), isEmpty);
    });
  });
}
