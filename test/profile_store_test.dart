import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';

void main() {
  late Directory dir;
  late ProfileStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('trefoil-store');
    store = ProfileStore(directory: dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Outbound server(String tag) =>
      ShareLink.parse('ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#$tag')!;

  test('a chosen language survives a save and load', () async {
    // save() used to re-implement encode() and had drifted from it: it never wrote
    // localeCode, so picking a language stuck until the app was next launched and
    // then silently reverted to the system one.
    await store.save(const ProfileData(localeCode: 'id'));
    expect((await store.load()).localeCode, 'id');
  });

  test('going back to the system language is persisted too', () async {
    await store.save(const ProfileData(localeCode: 'id'));
    await store.save(const ProfileData());
    expect((await store.load()).localeCode, isNull);
  });

  test('what save writes is what a backup carries', () async {
    // The two used to be separate copies of the same logic, which is how the field
    // above went missing from one of them.
    final data = ProfileData(
      servers: [server('a')],
      selectedTag: 'a',
      settings: ConfigBuilder(routing: RoutingSettings.defaults),
      localeCode: 'ar',
    );
    await store.save(data);

    final onDisk = jsonDecode(File('${dir.path}/profiles.json').readAsStringSync());
    expect(onDisk, store.encode(data));
  });

  test('overlapping saves leave a readable document', () async {
    // Every write goes through one temp path before the rename. Two of them at once
    // used to interleave into that file, and the rename published the mixture --
    // which reads back as an empty profile, i.e. every server gone.
    final writes = [
      for (var i = 0; i < 30; i++)
        store.save(ProfileData(servers: [for (var j = 0; j <= i; j++) server('server-$j')])),
    ];
    await Future.wait(writes);

    final loaded = await store.load();
    // The last write wins; what matters is that the document parses and is one of
    // the versions actually written, not a splice of two.
    expect(loaded.servers, hasLength(30));
    expect(loaded.servers.last.tag, 'server-29');
  });

  test('a corrupt document reads as empty rather than throwing', () async {
    File('${dir.path}/profiles.json').writeAsStringSync('{"version": 3, "servers": [{');
    expect((await store.load()).servers, isEmpty);
  });

  // Losing one entry is one entry. Losing the file over it was every server.
  group('a document with damage in it', () {
    Map<String, Object?> document(List<Object?> servers) => {
      ...store.encode(ProfileData(servers: [server('a')], selectedTag: 'a', localeCode: 'id')),
      'servers': servers,
    };
    Map<String, Object?> stored(String tag) => server(tag).toStorage();

    Future<void> write(Object document) =>
        File('${dir.path}/profiles.json').writeAsString(jsonEncode(document));

    File aside() => File('${dir.path}/profiles.json.corrupt');

    test('keeps every entry that can be read', () async {
      await write(
        document([
          stored('a'),
          {'tag': 'b', 'json': 'not a map'},
          'nonsense',
          null,
          stored('c'),
        ]),
      );
      final data = await store.load();
      expect(data.servers.map((s) => s.tag), ['a', 'c']);
      expect(data.localeCode, 'id', reason: 'what was readable is kept');
      expect(data.damaged, isTrue, reason: 'and the user is told');
    });

    test('keeps the servers when it is the settings that cannot be read', () async {
      await write({
        ...document([stored('a')]),
        'settings': ['not', 'a', 'map'],
        'hapticFeedback': 'yes',
      });
      final data = await store.load();
      expect(data.servers.single.tag, 'a');
      expect(data.hapticFeedback, isTrue);
      expect(data.damaged, isTrue);
    });

    // The next save replaces the file, so whatever was in it has to be somewhere else
    // by then.
    test('is copied before anything can replace it', () async {
      const text = '{"version": 4, "servers": [{';
      File('${dir.path}/profiles.json').writeAsStringSync(text);
      expect((await store.load()).damaged, isTrue);
      await store.save(const ProfileData());
      expect(aside().readAsStringSync(), text);
    });

    test('an empty file has nothing to keep a copy of', () async {
      File('${dir.path}/profiles.json').writeAsStringSync('');
      await store.load();
      expect(aside().existsSync(), isFalse);
    });

    test('a whole one is neither copied nor called damaged', () async {
      await store.save(ProfileData(servers: [server('a')]));
      expect((await store.load()).damaged, isFalse);
      expect(aside().existsSync(), isFalse);
    });

    // A restore replaces everything, so there a half-read document is no document.
    test('is refused whole when it is a backup', () {
      expect(() => store.decode(document([stored('a'), 'nonsense'])), throwsA(anything));
    });
  });

  // A server added by hand keeps whatever the parser of the day made of its link.
  group('a profile from an earlier version', () {
    const link =
        'vless://11111111-2222-3333-4444-555555555555@192.0.2.1:443?security=reality'
        '&sni=a.example&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI+T4E7RoLJS0#Link%20name';

    Map<String, Object?> older(Outbound saved) => {
      ...store.encode(const ProfileData()),
      'version': 3,
      'servers': [saved.toStorage()],
      'selectedTag': saved.tag,
    };

    /// The same server as the old parser left it: the key's plus read as a space.
    Outbound misread() {
      final parsed = ShareLink.parse(link)!;
      final json = jsonDecode(jsonEncode(parsed.json)) as Map<String, Object?>;
      ((json['tls'] as Map)['reality'] as Map)['public_key'] =
          'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI T4E7RoLJS0';
      return Outbound(
        tag: 'My name',
        type: parsed.type,
        json: {...json, 'tag': 'My name'},
        link: link,
        subscriptionId: 'sub',
      );
    }

    test('has its links read again, under the names the user gave', () async {
      File('${dir.path}/profiles.json').writeAsStringSync(jsonEncode(older(misread())));
      final data = await store.load();
      final mended = data.servers.single;
      expect(
        ((mended.json['tls'] as Map)['reality'] as Map)['public_key'],
        'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
      );
      expect(mended.tag, 'My name');
      expect(mended.subscriptionId, 'sub');
      expect(data.selectedTag, 'My name');
      expect(data.damaged, isFalse);
    });

    test('is written back once it has been', () async {
      final file = File('${dir.path}/profiles.json')
        ..writeAsStringSync(jsonEncode(older(misread())));
      await store.load();
      // Behind the same queue as every other write.
      await store.save(await store.load());
      expect((jsonDecode(file.readAsStringSync()) as Map)['version'], 4);
    });

    test('keeps a server whose link says something else entirely', () {
      final saved = Outbound(
        tag: 'S',
        type: 'trojan',
        json: const {'type': 'trojan', 'server': '192.0.2.1', 'server_port': 443, 'tag': 'S'},
        link: link,
      );
      expect(store.decode(older(saved)).servers.single.type, 'trojan');
    });
  });

  // Providers write what they like in this header, and it is read on every refresh: an
  // exception here was a subscription that could never be imported.
  group('subscription usage', () {
    test('ordinary figures', () {
      final usage = SubscriptionUsage.parse(
        'upload=100; download=200; total=1000; expire=1893456000',
      );
      expect((usage.upload, usage.download, usage.total), (100, 200, 1000));
      expect(usage.expiresAt, DateTime.fromMillisecondsSinceEpoch(1893456000 * 1000));
    });

    test('what is not a figure is nothing', () {
      for (final value in ['Infinity', '-Infinity', 'NaN', '1e300', '9223372036854775807', 'x']) {
        final usage = SubscriptionUsage.parse('upload=$value; total=$value; expire=$value');
        expect((usage.upload, usage.total, usage.expiresAt), (null, null, null), reason: value);
      }
    });

    test('an expiry in milliseconds is the same moment', () {
      expect(
        SubscriptionUsage.parse('expire=1893456000000').expiresAt,
        SubscriptionUsage.parse('expire=1893456000').expiresAt,
      );
    });

    test('zero is never', () {
      expect(SubscriptionUsage.parse('expire=0').expiresAt, isNull);
    });
  });

  test('a document from a newer schema is refused, not silently downgraded', () {
    // Typed, so the restore screen can say "update the app" in the user's language.
    expect(() => store.decode({'version': 99}), throwsA(isA<BackupTooNewException>()));
  });
}
