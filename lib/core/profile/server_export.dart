import 'dart:convert';

import 'outbound.dart';

/// A server list in the shape every other client already knows how to read.
///
/// Servers could only ever come into this app — by link, by QR, by subscription, by
/// `.conf` — and never leave it. That makes moving to a new phone, or handing one
/// server to someone else, a matter of finding the original link again, which for a
/// subscription nobody has.
///
/// The format is the one providers ship: the share links, one per line, base64 over
/// the whole thing. Deliberately not a format of this app's own, and deliberately the
/// same one [ShareLink.parseSubscription] reads, so what comes out goes back in — here
/// or anywhere else.
class ServerExport {
  const ServerExport({required this.body, required this.exported, required this.skipped});

  /// Base64 of the newline-joined links. Empty when there was nothing to export.
  final String body;

  /// How many servers made it in.
  final int exported;

  /// How many had no share link to write down.
  ///
  /// A custom outbound pasted as raw JSON never had one, and so does a server saved
  /// before the app started keeping links. Silently exporting a shorter list than the
  /// one on screen is how someone restores onto a new phone and finds servers gone,
  /// so the count is carried out to be shown.
  final int skipped;

  bool get isEmpty => exported == 0;

  static ServerExport of(Iterable<Outbound> servers) {
    final links = <String>[];
    var skipped = 0;
    for (final server in servers) {
      final link = server.link;
      if (link == null || link.trim().isEmpty) {
        skipped++;
      } else {
        links.add(link.trim());
      }
    }
    return ServerExport(
      body: links.isEmpty ? '' : base64.encode(utf8.encode(links.join('\n'))),
      exported: links.length,
      skipped: skipped,
    );
  }
}
