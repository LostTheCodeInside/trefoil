import 'dart:convert';

import 'loopback_auth.dart';
import 'outbound.dart';
import 'server_check.dart';
import 'share_link.dart';

/// Splitting the TLS handshake so a filter that inspects it sees no whole record.
///
/// Only the Xray core can do this, so it reaches only the servers that run there —
/// which in this app means VLESS links needing something sing-box has no field for.
/// Everything else ignores it entirely, and the settings screen says so rather than
/// letting the reader believe a switch is doing something it is not.
class TlsTricks {
  const TlsTricks({
    this.fragment = false,
    this.packets = 'tlshello',
    this.length = '10-30',
    this.interval = '10-20',
  });

  final bool fragment;

  /// Which packets to split. `tlshello` is the handshake alone, which is the one
  /// worth splitting; `1-3` splits the first few of any connection.
  final String packets;

  /// Bytes per fragment, as an inclusive range.
  final String length;

  /// Milliseconds between fragments, as an inclusive range. Too small and the
  /// pieces arrive coalesced anyway; too large and every connection drags.
  final String interval;

  bool get isActive => fragment;

  TlsTricks copyWith({bool? fragment, String? packets, String? length, String? interval}) =>
      TlsTricks(
        fragment: fragment ?? this.fragment,
        packets: packets ?? this.packets,
        length: length ?? this.length,
        interval: interval ?? this.interval,
      );

  Map<String, Object?> toJson() => {
    'fragment': fragment,
    'packets': packets,
    'length': length,
    'interval': interval,
  };

  factory TlsTricks.fromJson(Map<String, Object?> map) => TlsTricks(
    fragment: map['fragment'] as bool? ?? false,
    packets: map['packets'] as String? ?? 'tlshello',
    length: map['length'] as String? ?? '10-30',
    interval: map['interval'] as String? ?? '10-20',
  );

  /// A range like `10-30`, or a single number. Rejected shapes are what Xray refuses
  /// at start, which would surface as the tunnel simply not coming up.
  static bool isValidRange(String value) {
    final parts = value.split('-');
    if (parts.isEmpty || parts.length > 2) return false;
    final numbers = parts.map(int.tryParse).toList();
    if (numbers.any((e) => e == null || e < 0)) return false;
    return numbers.length == 1 || numbers[0]! <= numbers[1]!;
  }
}

/// Builds an Xray-core config for servers the sing-box core cannot run.
///
/// Xray is not a replacement tunnel here. It runs as a loopback SOCKS5 server and
/// sing-box dials it as an ordinary outbound, so the TUN, DNS, routing and per-app
/// handling all stay in sing-box exactly as they are for every other server.
///
/// The config is built from the original share link rather than from the sing-box
/// outbound, because the two schemas disagree about almost everything: Xray nests
/// the server under `settings.vnext`, keeps TLS in `streamSettings`, and names
/// fields in camelCase. Translating between them would lose detail in both
/// directions — most importantly `mldsa65Verify`, VLESS encryption and XHTTP, which
/// are the whole reason Xray is here at all.
class XrayConfig {
  const XrayConfig._();

  /// Returns null when the link is not something Xray is needed for, or cannot be
  /// expressed — callers fall back to sing-box.
  ///
  /// The SOCKS5 inbound sing-box hands traffic to listens where [loopback] says and
  /// refuses anyone without its credentials; see [LoopbackAuth] for why. Left out,
  /// a fresh set is drawn — fine for asking whether a server converts at all, and a
  /// mismatch with the sing-box side fails loudly rather than opening anything.
  static String? build(
    Outbound outbound, {
    TlsTricks tricks = const TlsTricks(),
    LoopbackAuth? loopback,
  }) {
    final link = outbound.link;
    if (link == null || !link.startsWith('vless://')) return null;

    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty || uri.port == 0) return null;
    final uuid = Uri.decodeComponent(uri.userInfo);
    if (uuid.isEmpty) return null;
    final q = ShareLink.query(uri);
    final auth = loopback ?? LoopbackAuth.random();

    final config = <String, Object?>{
      // Xray writes to stdout/stderr, which on Android goes nowhere useful; keep it
      // quiet so it cannot flood logcat from a background service.
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'socks-in',
          'listen': '127.0.0.1',
          'port': auth.xrayPort,
          'protocol': 'socks',
          'settings': {
            'auth': 'password',
            'accounts': [
              {'user': auth.username, 'pass': auth.password},
            ],
            'udp': true,
            'ip': '127.0.0.1',
          },
          // sing-box already sniffed and routed before handing the connection over;
          // sniffing a second time here would only cost CPU.
          'sniffing': {'enabled': false},
        },
      ],
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': uri.host,
                'port': uri.port,
                'users': [
                  {
                    'id': uuid,
                    // Required, and "none" unless the server wants VLESS's own
                    // encryption on top of whatever carries it.
                    'encryption': switch (q['encryption']) {
                      final String value when value.isNotEmpty => value,
                      _ => 'none',
                    },
                    if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
                    'level': 0,
                  },
                ],
              },
            ],
          },
          'streamSettings': _streamSettings(q, uri.host, tricks),
        },
        // The dialer the outbound above hands its socket to. Present only when the
        // splitting is on, because an unreferenced freedom outbound is dead weight.
        if (tricks.isActive)
          {
            'tag': fragmentTag,
            'protocol': 'freedom',
            'settings': {
              'fragment': {
                'packets': tricks.packets,
                'length': tricks.length,
                'interval': tricks.interval,
              },
            },
          },
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(config);
  }

  /// The freedom outbound that does the splitting.
  static const fragmentTag = 'fragment';

  static Map<String, Object?> _streamSettings(
    Map<String, String> q,
    String host,
    TlsTricks tricks,
  ) {
    // Absent and empty both mean plain TCP. Written the long way because the short
    // way read as if it handled the absent case and did not: `q['type'] ?? 'tcp'` is
    // never empty, so the branch that dereferenced `q['type']!` was the one taken
    // whenever the parameter was missing, and a link without it crashed the connect.
    final network = switch (q['type']) {
      final String type when type.isNotEmpty => type,
      _ => 'tcp',
    };
    final security = q['security'] ?? 'none';

    final stream = <String, Object?>{
      'network': network,
      'security': security == 'reality' ? 'reality' : (security == 'tls' ? 'tls' : 'none'),
      // Routes this outbound's socket through the fragmenting dialer.
      if (tricks.isActive) 'sockopt': {'dialerProxy': fragmentTag},
    };

    // Xray refuses to start over a name it does not know, as sing-box does.
    final fingerprint = ServerCheck.fingerprint(q['fp'] ?? '');
    if (security == 'reality') {
      stream['realitySettings'] = {
        'serverName': q['sni'] ?? host,
        // REALITY without a uTLS fingerprint is trivially fingerprintable, and Xray
        // rejects an empty one outright.
        'fingerprint': fingerprint.isEmpty ? 'chrome' : fingerprint,
        if ((q['pbk'] ?? '').isNotEmpty) 'publicKey': ServerCheck.realityKey(q['pbk']!),
        if ((q['sid'] ?? '').isNotEmpty) 'shortId': q['sid'],
        if ((q['spx'] ?? '').isNotEmpty) 'spiderX': q['spx'],
        // The post-quantum verification key. sing-box has no field for this.
        if ((q['pqv'] ?? '').isNotEmpty) 'mldsa65Verify': q['pqv'],
      };
    } else if (security == 'tls') {
      stream['tlsSettings'] = {
        'serverName': q['sni'] ?? q['host'] ?? host,
        if (fingerprint.isNotEmpty) 'fingerprint': fingerprint,
        if ((q['alpn'] ?? '').isNotEmpty)
          'alpn': q['alpn']!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        // Xray no longer takes `allowInsecure`, and refuses a config that has it. A
        // self-signed server is reached by naming its certificate instead.
        if ((q['pcs'] ?? '').isNotEmpty) 'pinnedPeerCertSha256': q['pcs'],
        if ((q['vcn'] ?? '').isNotEmpty) 'verifyPeerCertByName': q['vcn'],
        if ((q['ech'] ?? '').isNotEmpty) 'echConfigList': q['ech'],
      };
    }

    switch (network) {
      case 'ws':
        stream['wsSettings'] = {
          if ((q['path'] ?? '').isNotEmpty) 'path': q['path'],
          if ((q['host'] ?? '').isNotEmpty) 'headers': {'Host': q['host']},
        };
      case 'grpc':
        stream['grpcSettings'] = {
          if ((q['serviceName'] ?? '').isNotEmpty) 'serviceName': q['serviceName'],
        };
      case 'httpupgrade':
        stream['httpupgradeSettings'] = {
          if ((q['path'] ?? '').isNotEmpty) 'path': q['path'],
          if ((q['host'] ?? '').isNotEmpty) 'host': q['host'],
        };
      case 'xhttp' || 'splithttp':
        stream['xhttpSettings'] = {
          if ((q['path'] ?? '').isNotEmpty) 'path': q['path'],
          if ((q['host'] ?? '').isNotEmpty) 'host': q['host'],
          if ((q['mode'] ?? '').isNotEmpty) 'mode': q['mode'],
          'extra': ?_extra(q['extra'] ?? ''),
        };
    }
    return stream;
  }

  /// XHTTP's remaining settings, which a link carries as one JSON object.
  ///
  /// Null when there is none to read. A link written by a form encoder has its spaces
  /// as pluses, and those are the only pluses that make JSON unreadable.
  static Map<String, Object?>? _extra(String value) {
    if (value.isEmpty) return null;
    for (final text in {value, value.replaceAll('+', ' ')}) {
      try {
        if (jsonDecode(text) case final Map<String, Object?> extra) return extra;
      } on FormatException {
        continue;
      }
    }
    return null;
  }
}
