import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/tunnel_status.dart';

/// Which app a connection belongs to, as it arrives from the core.
///
/// The core only resolves this when something asked it to — a `package_name` routing
/// rule is what does — so every shape below is one the UI actually meets.
void main() {
  ActiveConnection decode(Map<Object?, Object?> map) => ActiveConnection.fromMap(map);

  test('the resolved package comes through', () {
    final connection = decode({
      'id': '1',
      'packages': ['com.example.one'],
    });
    expect(connection.packages, ['com.example.one']);
    expect(connection.appPackage, 'com.example.one');
  });

  test('a connection the core said nothing about names no app', () {
    expect(decode({'id': '1'}).appPackage, '');
    expect(decode({'id': '1', 'packages': <Object?>[]}).appPackage, '');
  });

  // A uid shared between packages reports all of them, and the list must not come
  // back holding a null or an empty string for the UI to render.
  test('several packages keep their order and lose their blanks', () {
    final connection = decode({
      'id': '1',
      'packages': ['com.example.one', '', null, 'com.example.two'],
    });
    expect(connection.packages, ['com.example.one', 'com.example.two']);
    expect(connection.appPackage, 'com.example.one');
  });

  // The inbound's authenticated user is a different field that used to be described
  // as the app, which is how it ended up in the subtitle where the app belongs.
  test('the auth user is not the app', () {
    final connection = decode({'id': '1', 'user': 'someone'});
    expect(connection.user, 'someone');
    expect(connection.appPackage, '');
  });
}
