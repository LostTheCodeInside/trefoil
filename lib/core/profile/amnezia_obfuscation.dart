/// What an AmneziaWG server's obfuscation settings will cost in lost packets.
///
/// AmneziaWG decides what an arriving packet is by trying initiation, then response,
/// then cookie, and only then transport. With `RandomTrailers` on, the first three
/// tests accept any packet *longer* than the message they are looking for — which is
/// every data packet — and the decision then rests on four bytes read at that
/// message type's own junk-prefix offset (`S1`, `S2`, `S3`). In a data packet those
/// bytes are ciphertext, so they are uniformly random, and a header range covering
/// `n` of the 2^32 values claims `n / 2^32` of them. Every claimed packet fails its
/// MAC check and is dropped.
///
/// It is quiet, and it is expensive. Measured against a real server whose ranges
/// summed to 2.14%: 2.30% of packets dropped, and a single TCP stream held to
/// 0.4 MB/s where the same fetch outside the tunnel carried 9 MB/s — TCP cannot go
/// fast through steady loss. Turning the trailers off took the same stream to
/// 7.7 MB/s.
///
/// Two shapes are safe. If `S1`–`S4` are all equal, every test reads the *real* type
/// field, which was drawn from `H4` and so cannot fall in `H1`–`H3`. And a header
/// value that is a single number rather than a range covers 1 of 4 billion. Both are
/// what the AmneziaWG documentation recommends; neither is what generators emit.
library;

/// The fraction of packets this config will lose, between 0 and 1. Zero when the
/// config is safe, is not AmneziaWG, or says nothing about any of this.
///
/// Reported per branch, because a branch whose `S` matches the transport one is
/// harmless however wide its range is.
double amneziaObfuscationLoss(String conf) {
  final values = _values(conf);
  if (!_truthy(values['randomtrailers'])) return 0;

  final transportPrefix = _number(values['s4']);
  var lost = 0.0;
  for (final (prefix, header) in [('s1', 'h1'), ('s2', 'h2'), ('s3', 'h3')]) {
    // Same prefix as a data packet's means this test reads the real type field, and
    // the real type field came from H4.
    if (_number(values[prefix]) == transportPrefix) continue;
    lost += _width(values[header]) / 4294967296;
  }
  return lost;
}

/// `Key = value` pairs, lower-cased, from every section — the ones that matter here
/// only ever appear under `[Interface]`, and a peer has nothing that collides.
Map<String, String> _values(String conf) {
  final out = <String, String>{};
  for (final line in conf.split('\n')) {
    final text = line.trim();
    if (text.isEmpty || text.startsWith('#') || text.startsWith('[')) continue;
    final split = text.indexOf('=');
    if (split <= 0) continue;
    out[text.substring(0, split).trim().replaceAll(' ', '').toLowerCase()] = text
        .substring(split + 1)
        .trim();
  }
  return out;
}

bool _truthy(String? value) => switch (value?.trim().toLowerCase()) {
  'on' || 'true' || 'yes' || '1' => true,
  _ => false,
};

int _number(String? value) => int.tryParse(value?.trim() ?? '') ?? 0;

/// How many values a header setting covers. `410000001-416021364` is a range;
/// anything else is one value, including the 1/2/3/4 that mean "no custom header".
int _width(String? value) {
  final text = value?.trim() ?? '';
  final dash = text.indexOf('-', 1);
  if (dash < 0) return 1;
  final low = int.tryParse(text.substring(0, dash).trim());
  final high = int.tryParse(text.substring(dash + 1).trim());
  if (low == null || high == null || high < low) return 1;
  return high - low + 1;
}
