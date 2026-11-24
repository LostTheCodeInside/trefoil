import 'dart:convert';

import 'outbound.dart';

/// Reads WireGuard servers, from either a share link or a `.conf` file.
///
/// Two formats, because providers hand out both. The `wireguard://` link is what
/// the phone clients emit and what fits in a QR code; the `[Interface]`/`[Peer]`
/// file is what every WireGuard provider and every self-hosted server produces, and
/// pasting one is the path most people will actually take.
///
/// Unlike the other protocols this becomes a sing-box *endpoint* rather than an
/// outbound. Endpoints share the tag namespace with outbounds, so such a server can
/// still sit in the selector, be latency-tested and be switched to without a
/// reconnect — verified against the real binary.
class WireGuardConfig {
  const WireGuardConfig._();

  /// sing-box's own type name for these.
  static const type = 'wireguard';

  /// What most servers use when the config does not say.
  static const defaultPort = 51820;

  /// Below the usual 1500 to leave room for WireGuard's own header. 1408 is what
  /// wg-quick picks on a plain IPv4 path and what most providers ship.
  static const defaultMtu = 1408;

  /// Whether [text] is a `[Interface]` file rather than a link.
  static bool looksLikeConf(String text) =>
      RegExp(r'^\s*\[Interface\]', multiLine: true, caseSensitive: false).hasMatch(text);

  /// Parses either form. Returns null when it is neither, or is missing something
  /// WireGuard cannot work without.
  /// Keys that mean the handshake is not WireGuard's any more.
  ///
  /// AmneziaWG reshapes the handshake itself — junk packets before it, rewritten
  /// header words, and in the newer revisions a protected header and randomised
  /// trailers. sing-box has no field for any of it, and the keys are not decoration:
  /// a server configured this way rejects an ordinary WireGuard handshake outright.
  ///
  /// Which is exactly why they cannot be ignored. Reading such a config as plain
  /// WireGuard would yield a server that looks perfectly fine in the list, sits in
  /// the selector, and can never connect to anything. Their presence routes the
  /// server to the third core instead.
  static const amneziaKeys = {
    'jc',
    'jmin',
    'jmax',
    's1',
    's2',
    's3',
    's4',
    'h1',
    'h2',
    'h3',
    'h4',
    'i1',
    'i2',
    'i3',
    'i4',
    'i5',
    'headerprotectionkey',
    'contentpaddingaddition',
    'randomtrailers',
    'disablecookies',
    'maxhandshakeattempts',
  };

  static Outbound? parse(String source, {String? name}) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return null;
    // Amnezia hands out `vpn://<base64 of the .conf>`. Decoded here rather than
    // refused, so what comes back is a reason instead of "unsupported share link".
    if (trimmed.toLowerCase().startsWith('vpn://')) {
      final decoded = _decodeBase64(trimmed.substring('vpn://'.length));
      if (decoded == null || !looksLikeConf(decoded)) return null;
      return parseConf(decoded, name: name);
    }
    if (looksLikeConf(trimmed)) return parseConf(trimmed, name: name);
    if (trimmed.toLowerCase().startsWith('wireguard://') ||
        trimmed.toLowerCase().startsWith('wg://')) {
      return parseLink(trimmed, name: name);
    }
    return null;
  }

  // ---- the .conf file ----------------------------------------------------

  /// A wg-quick configuration: `[Interface]` with the key and addresses, `[Peer]`
  /// with the server. Only the first peer is used — sing-box supports several, but
  /// a config with more than one is a mesh rather than a proxy, and picking one
  /// arbitrarily would be worse than being predictable.
  static Outbound? parseConf(String source, {String? name}) {
    final sections = _sections(source);
    final iface = sections['interface'] ?? const {};
    final peer = sections['peer'] ?? const {};

    final privateKey = iface['privatekey'] ?? '';
    final publicKey = peer['publickey'] ?? '';
    final endpoint = peer['endpoint'] ?? '';
    if (privateKey.isEmpty || publicKey.isEmpty || endpoint.isEmpty) return null;

    final (host, port) = _hostPort(endpoint);
    if (host.isEmpty) return null;

    final addresses = _prefixes(iface['address'] ?? '');
    if (addresses.isEmpty) return null;

    return _build(
      // A name passed in wins; then the one the file names itself; then the address,
      // which is a poor name but never a wrong one.
      tag: switch ((name?.trim(), _commentName(source))) {
        (final String given, _) when given.isNotEmpty => given,
        (_, final String labelled) when labelled.isNotEmpty => labelled,
        _ => host,
      },
      privateKey: privateKey,
      publicKey: publicKey,
      preSharedKey: peer['presharedkey'] ?? '',
      host: host,
      port: port,
      addresses: addresses,
      mtu: int.tryParse(iface['mtu'] ?? '') ?? defaultMtu,
      keepalive: int.tryParse(peer['persistentkeepalive'] ?? '') ?? 0,
      reserved: const [],
      // Handed to the third core verbatim. The sing-box side of this server is only
      // ever the loopback SOCKS port that core opens.
      amneziaConf: _isAmnezia(iface) ? source : null,
    );
  }

  /// Tolerant base64, the same way share links need it: providers use the URL-safe
  /// alphabet as often as the standard one, and strip the padding as often as not.
  static String? _decodeBase64(String value) {
    var normalized = value
        .trim()
        .replaceAll(RegExp(r'\s'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    normalized = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
    try {
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// The name a config file gives itself, if it gives one.
  ///
  /// Amnezia writes the server's name as a comment above `[Peer]`, and it is the only
  /// name in the file — without it an import is titled by its address, which is
  /// unhelpful the moment someone has two servers on one host, as anyone running
  /// their own does.
  ///
  /// The first comment only. Later ones are as likely to be someone's notes.
  static String _commentName(String source) {
    for (final line in const LineSplitter().convert(source)) {
      final text = line.trim();
      if (!text.startsWith('#') && !text.startsWith(';')) continue;
      final name = text.substring(1).trim();
      if (name.isNotEmpty) return name;
    }
    return '';
  }

  /// Whether this config is AmneziaWG rather than WireGuard.
  ///
  /// One parameter is enough. They are not decoration: a server configured with any
  /// of them rejects an ordinary WireGuard handshake, so the choice of core is made
  /// by their presence and not by how many there are.
  static bool _isAmnezia(Map<String, String> iface) => iface.keys.any(amneziaKeys.contains);

  /// `[Section]` to its `key = value` pairs, keys lower-cased and space-stripped so
  /// `PersistentKeepalive`, `persistentkeepalive` and `Persistent Keepalive` all
  /// land in the same place. A repeated section wins with its last occurrence.
  static Map<String, Map<String, String>> _sections(String source) {
    final out = <String, Map<String, String>>{};
    var current = '';
    for (final rawLine in const LineSplitter().convert(source)) {
      // `#` and `;` both start a comment in the format wg-quick reads.
      final line = rawLine.split('#').first.split(';').first.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        current = line.substring(1, line.length - 1).trim().toLowerCase();
        out.putIfAbsent(current, () => {});
        continue;
      }
      final split = line.indexOf('=');
      if (split < 0 || current.isEmpty) continue;
      final key = line.substring(0, split).replaceAll(' ', '').toLowerCase();
      out[current]![key] = line.substring(split + 1).trim();
    }
    return out;
  }

  // ---- the link ----------------------------------------------------------

  /// `wireguard://<private key>@host:port?publickey=…&address=…&reserved=…#name`
  ///
  /// The key travels in the userinfo, url-encoded, which is how the clients that
  /// emit this write it.
  static Outbound? parseLink(String link, {String? name}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final q = uri.queryParameters;

    // Some clients put the private key in the query instead of the userinfo.
    final privateKey = _decodeKey(
      uri.userInfo.isNotEmpty ? uri.userInfo : (q['privatekey'] ?? q['secretkey'] ?? ''),
    );
    final publicKey = _decodeKey(q['publickey'] ?? q['peerpublickey'] ?? '');
    if (privateKey.isEmpty || publicKey.isEmpty) return null;

    final addresses = _prefixes(q['address'] ?? q['ip'] ?? '');
    if (addresses.isEmpty) return null;

    return _build(
      tag: name?.trim().isNotEmpty == true ? name!.trim() : (_fragment(uri) ?? uri.host),
      privateKey: privateKey,
      publicKey: publicKey,
      preSharedKey: _decodeKey(q['presharedkey'] ?? ''),
      host: uri.host,
      port: uri.hasPort ? uri.port : defaultPort,
      addresses: addresses,
      mtu: int.tryParse(q['mtu'] ?? '') ?? defaultMtu,
      keepalive: int.tryParse(q['keepalive'] ?? q['persistentkeepalive'] ?? '') ?? 0,
      reserved: _reserved(q['reserved'] ?? ''),
    );
  }

  // ---- shared ------------------------------------------------------------

  static Outbound _build({
    required String tag,
    required String privateKey,
    required String publicKey,
    required String preSharedKey,
    required String host,
    required int port,
    required List<String> addresses,
    required int mtu,
    required int keepalive,
    required List<int> reserved,
    String? amneziaConf,
  }) => Outbound(
    tag: tag,
    type: type,
    amneziaConf: amneziaConf,
    json: {
      'type': type,
      'tag': tag,
      'mtu': mtu,
      'address': addresses,
      'private_key': privateKey,
      'peers': [
        {
          'address': host,
          'port': port,
          'public_key': publicKey,
          if (preSharedKey.isNotEmpty) 'pre_shared_key': preSharedKey,
          // Everything, because this is a proxy rather than a split-tunnel peer.
          // A config that allows only part of the space would route the rest
          // nowhere, which reads as a tunnel that connects and carries nothing.
          'allowed_ips': ['0.0.0.0/0', '::/0'],
          if (reserved.length == 3) 'reserved': reserved,
          if (keepalive > 0) 'persistent_keepalive_interval': keepalive,
        },
      ],
    },
  );

  /// `10.0.0.2/32, fd00::2/128` in either format, and a bare address gets the full
  /// prefix sing-box requires.
  static List<String> _prefixes(String value) => [
    for (final part in value.split(','))
      if (part.trim().isNotEmpty) _withPrefix(part.trim()),
  ];

  static String _withPrefix(String address) {
    if (address.contains('/')) return address;
    return address.contains(':') ? '$address/128' : '$address/32';
  }

  /// `host:port`, with IPv6 in brackets.
  static (String, int) _hostPort(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('[')) {
      final close = trimmed.indexOf(']');
      if (close < 0) return ('', 0);
      final host = trimmed.substring(1, close);
      final rest = trimmed.substring(close + 1);
      return (host, int.tryParse(rest.replaceFirst(':', '')) ?? defaultPort);
    }
    final colon = trimmed.lastIndexOf(':');
    if (colon < 0) return (trimmed, defaultPort);
    return (trimmed.substring(0, colon), int.tryParse(trimmed.substring(colon + 1)) ?? defaultPort);
  }

  /// Keys are base64. Links url-encode them, and `+` and `/` are what gets mangled.
  static String _decodeKey(String value) {
    if (value.isEmpty) return '';
    final decoded = Uri.decodeComponent(value).trim();
    // Some clients emit url-safe base64; sing-box wants the standard alphabet.
    return decoded.replaceAll('-', '+').replaceAll('_', '/');
  }

  /// Cloudflare-style reserved bytes, as `1,2,3` or as base64.
  static List<int> _reserved(String value) {
    if (value.isEmpty) return const [];
    if (value.contains(',')) {
      final parts = value.split(',').map((e) => int.tryParse(e.trim())).toList();
      if (parts.length != 3 || parts.any((e) => e == null || e < 0 || e > 255)) return const [];
      return parts.cast<int>();
    }
    try {
      final bytes = base64.decode(_padded(value));
      return bytes.length >= 3 ? bytes.take(3).toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  static String _padded(String value) {
    final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
    return normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
  }

  static String? _fragment(Uri uri) {
    if (uri.fragment.isEmpty) return null;
    try {
      return Uri.decodeComponent(uri.fragment);
    } catch (_) {
      return uri.fragment;
    }
  }
}
