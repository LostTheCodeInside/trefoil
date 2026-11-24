import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/action_error.dart';
import 'package:trefoil/core/profile/profile_store.dart';
import 'package:trefoil/core/tunnel_channel.dart';
import 'package:trefoil/l10n/app_localizations.dart';
import 'package:trefoil/ui/error_text.dart';

/// Failures are said in the user's language.
///
/// They used to be English sentences built in the core, which is what most people
/// using this app — in Persian, Russian, Chinese — read at the exact moment
/// something had gone wrong.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final id = lookupAppLocalizations(const Locale('id'));

  test('a refused subscription says why, with the status', () {
    const error = SubscriptionException.http(403);
    expect(describeError(en, error), contains('refused'));
    expect(describeError(id, error), allOf(contains('menolak'), contains('403')));
  });

  test('statuses are told apart by what the user can do about them', () {
    String kind(int status) => ActionError.from(SubscriptionException.http(status)).kind.name;
    expect(kind(401), 'subscriptionRefused');
    expect(kind(404), 'subscriptionNotFound');
    expect(kind(429), 'subscriptionRateLimited');
    expect(kind(502), 'subscriptionServerError');
    expect(kind(418), 'subscriptionHttp');
  });

  test('native codes are translated, not shown as their English message', () {
    const wrong = TunnelException('wrong_password', 'Wrong password, or the backup is damaged');
    expect(describeError(id, wrong), id.errorWrongPassword);
  });

  // The sentence is translated; what only makes sense verbatim is kept as it came.
  test('technical detail is appended untranslated', () {
    final text = describeError(
      id,
      const ActionError(ActionErrorKind.configRejected, detail: 'unknown field "foo"'),
    );
    expect(text, startsWith(id.errorConfigRejected));
    expect(text, endsWith('unknown field "foo"'));
  });

  test('a failure underneath is said after what was being attempted', () {
    final text = describeError(
      en,
      ActionError(ActionErrorKind.warpRegistration, cause: ActionError.from(TimeoutException('t'))),
    );
    expect(text, '${en.errorWarpRegistration}: ${en.errorTimeout}');
  });

  test('an unreachable host is named', () {
    final error = SocketException('Failed host lookup', address: InternetAddress('192.0.2.1'));
    expect(describeError(en, error), contains('192.0.2.1'));
  });

  test('anything unrecognised keeps its own words', () {
    expect(describeError(en, StateError('odd')), contains('odd'));
  });

  // The notification, tile and widget are drawn natively, from Android resources,
  // often with no Flutter engine to ask. A string missing from one language there
  // silently shows English in the shade while the app speaks something else.
  test('every native string exists in every shipped language', () {
    Set<String> names(String dir) =>
        RegExp(r'<string name="([^"]+)"')
            .allMatches(File('android/app/src/main/res/$dir/strings.xml').readAsStringSync())
            .map((m) => m.group(1)!)
            .toSet();
    final base = names('values');
    expect(base, isNotEmpty);
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      expect(names('values-${locale.languageCode}'), base, reason: locale.languageCode);
    }
  });
}
