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

  test('a document from a newer schema is refused, not silently downgraded', () {
    // Typed, so the restore screen can say "update the app" in the user's language.
    expect(() => store.decode({'version': 99}), throwsA(isA<BackupTooNewException>()));
  });
}
