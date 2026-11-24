import 'dart:convert';

import 'clash_config.dart';
import 'outbound.dart';
import 'wireguard_config.dart';

/// Parses proxy share links into sing-box outbounds.
///
/// There is no specification for any of these formats; they are what the popular
/// clients happen to emit. So every field is treated as optional, unknown values are
/// ignored rather than rejected, and a link that cannot be understood returns null
/// instead of throwing — one malformed entry in a 200-server subscription must not
/// cost the user the other 199.
class ShareLink {
  const ShareLink._();

  /// Parses one link. Returns null if the scheme is unknown or the link is malformed.
  static Outbound? parse(String raw) {
    final link = raw.trim();
    if (link.isEmpty) return null;
    try {
      return switch (Uri.tryParse(link)?.scheme.toLowerCase()) {
        'vmess' => _vmess(link),
        'vless' => _vless(link),
        'trojan' => _trojan(link),
        'ss' => _shadowsocks(link),
        'hysteria2' || 'hy2' => _hysteria2(link),
        'hysteria' || 'hy' => _hysteria(link),
        'tuic' => _tuic(link),
        'anytls' => _anytls(link),
        'socks' || 'socks5' => _socks(link),
        // Becomes an endpoint rather than an outbound; see WireGuardConfig.
        'wireguard' || 'wg' => WireGuardConfig.parseLink(link),
        // Amnezia's whole .conf in base64. A subscription carries it as one line among
        // the links, and without this case that line was dropped without a word.
        'vpn' => WireGuardConfig.parse(link),
        _ => null,
      }?.withLink(link);
    } catch (_) {
      return null;
    }
  }

  /// Parses a whole subscription body.
  ///
  /// Three shapes reach here: a newline-separated list of links, that same list
  /// base64-encoded as one blob, and a Clash/Meta YAML document. The first two are
  /// what most providers ship; the third is what a good number of paid ones ship
  /// instead, and it used to import as nothing at all.
  static List<Outbound> parseSubscription(String body, {String? subscriptionId}) {
    // Base64 first: a provider that encodes the body encodes it whichever format is
    // inside, so a Clash document can arrive wrapped too.
    final decoded = _looksBase64(body) ? _decodeBase64(body) ?? body : body;
    if (ClashConfig.looksLikeClash(decoded)) {
      return _withUniqueTags(ClashConfig.parse(decoded), subscriptionId);
    }
    return _withUniqueTags([
      for (final line in const LineSplitter().convert(decoded)) ?parse(line),
    ], subscriptionId);
  }

  /// Gives every server a name no other server in the list has.
  ///
  /// Tags become sing-box outbound tags, which must be unique or the config is
  /// rejected wholesale — not the offending entry, the whole thing. Providers
  /// routinely repeat names across entries, so this is load-bearing rather than
  /// cosmetic.
  static List<Outbound> _withUniqueTags(List<Outbound> parsed, String? subscriptionId) =>
      Outbound.withUniqueTags([
        for (final (i, server) in parsed.indexed)
          server.copyWith(
            tag: server.tag.isEmpty ? '${server.type}-${i + 1}' : server.tag,
            subscriptionId: subscriptionId,
          ),
      ]);

  // ---- per-protocol parsers ---------------------------------------------

  /// `vmess://<base64 of a JSON blob>` - the v2rayN format, whose fields are strings even
  /// when they hold numbers.
  static Outbound? _vmess(String link) {
    final payload = _decodeBase64(link.substring('vmess://'.length));
    if (payload == null) return null;
    final map = jsonDecode(payload) as Map<String, Object?>;

    String str(String key) => map[key]?.toString() ?? '';
    final server = str('add');
    final port = int.tryParse(str('port')) ?? 0;
    if (server.isEmpty || port == 0) return null;

    final json = <String, Object?>{
      'type': 'vmess',
      'server': server,
      'server_port': port,
      'uuid': str('id'),
      'security': str('scy').isEmpty ? 'auto' : str('scy'),
      if (int.tryParse(str('aid')) case final aid? when aid > 0) 'alter_id': aid,
    };

    final tls = str('tls');
    final network = str('net');
    final transport = _transport(
      network: network,
      path: str('path'),
      host: str('host'),
      serviceName: str('path'),
    );
    if (transport != null) json['transport'] = transport;
    if (tls == 'tls' || tls == 'reality') {
      json['tls'] = _tls(
        enabled: true,
        serverName: str('sni').isNotEmpty
            ? str('sni')
            : (str('host').isNotEmpty ? str('host') : server),
        alpn: str('alpn'),
        fingerprint: str('fp'),
        insecure: str('allowInsecure') == '1' || str('allowInsecure') == 'true',
      );
    }
    return Outbound(tag: str('ps').isEmpty ? server : str('ps'), type: 'vmess', json: json);
  }

  /// `vless://uuid@host:port?params#name`
  static Outbound? _vless(String link) {
    final uri = Uri.parse(link);
    final uuid = Uri.decodeComponent(uri.userInfo);
    if (uri.host.isEmpty || uri.port == 0 || uuid.isEmpty) return null;
    final q = uri.queryParameters;

    final json = <String, Object?>{
      'type': 'vless',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uuid,
      if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
    };

    final transport = _transport(
      network: q['type'] ?? 'tcp',
      path: q['path'] ?? '',
      host: q['host'] ?? '',
      serviceName: q['serviceName'] ?? '',
    );
    if (transport != null) json['transport'] = transport;

    final security = q['security'] ?? '';
    if (security == 'tls' || security == 'reality') {
      final tls = _tls(
        enabled: true,
        serverName: q['sni'] ?? q['host'] ?? uri.host,
        alpn: q['alpn'] ?? '',
        fingerprint: q['fp'] ?? '',
        insecure: q['allowInsecure'] == '1',
      );
      if (security == 'reality') {
        tls['reality'] = {
          'enabled': true,
          if ((q['pbk'] ?? '').isNotEmpty) 'public_key': q['pbk'],
          if ((q['sid'] ?? '').isNotEmpty) 'short_id': q['sid'],
        };
        // REALITY needs a uTLS fingerprint to be worth anything; providers often omit it.
        tls['utls'] = {
          'enabled': true,
          'fingerprint': (q['fp'] ?? '').isEmpty ? 'chrome' : q['fp'],
        };
      }
      json['tls'] = tls;
    }
    return Outbound(
      tag: _fragment(uri) ?? uri.host,
      type: 'vless',
      json: json,
      unsupported: _unsupportedFeatures(q),
      link: link,
      requiresXray: _requiresXray(q),
    );
  }

  /// `trojan://password@host:port?params#name`
  static Outbound? _trojan(String link) {
    final uri = Uri.parse(link);
    final password = Uri.decodeComponent(uri.userInfo);
    if (uri.host.isEmpty || uri.port == 0 || password.isEmpty) return null;
    final q = uri.queryParameters;

    final json = <String, Object?>{
      'type': 'trojan',
      'server': uri.host,
      'server_port': uri.port,
      'password': password,
      // Trojan is TLS-only by definition, so TLS is on even without ?security=tls.
      'tls': _tls(
        enabled: true,
        serverName: q['sni'] ?? q['peer'] ?? uri.host,
        alpn: q['alpn'] ?? '',
        fingerprint: q['fp'] ?? '',
        insecure: q['allowInsecure'] == '1',
      ),
    };
    final transport = _transport(
      network: q['type'] ?? 'tcp',
      path: q['path'] ?? '',
      host: q['host'] ?? '',
      serviceName: q['serviceName'] ?? '',
    );
    if (transport != null) json['transport'] = transport;
    return Outbound(tag: _fragment(uri) ?? uri.host, type: 'trojan', json: json);
  }

  /// `ss://...` in either the modern SIP002 form or the legacy fully-base64 form.
  static Outbound? _shadowsocks(String link) {
    final hash = link.indexOf('#');
    final name = hash >= 0 ? _decodeFragment(link.substring(hash + 1)) : null;
    var body = hash >= 0 ? link.substring('ss://'.length, hash) : link.substring('ss://'.length);

    String method;
    String password;
    String server;
    int port;

    final at = body.lastIndexOf('@');
    if (at >= 0) {
      // SIP002: ss://base64(method:password)@host:port
      final userInfo =
          _decodeBase64(body.substring(0, at)) ?? Uri.decodeComponent(body.substring(0, at));
      final split = userInfo.indexOf(':');
      if (split < 0) return null;
      method = userInfo.substring(0, split);
      password = userInfo.substring(split + 1);
      final hostPort = body.substring(at + 1).split('?').first;
      final colon = hostPort.lastIndexOf(':');
      if (colon < 0) return null;
      server = hostPort.substring(0, colon).replaceAll(RegExp(r'^\[|\]$'), '');
      port = int.tryParse(hostPort.substring(colon + 1)) ?? 0;
    } else {
      // Legacy: ss://base64(method:password@host:port)
      final decoded = _decodeBase64(body.split('?').first);
      if (decoded == null) return null;
      final at2 = decoded.lastIndexOf('@');
      final colon = decoded.lastIndexOf(':');
      if (at2 < 0 || colon < at2) return null;
      final userInfo = decoded.substring(0, at2);
      final split = userInfo.indexOf(':');
      if (split < 0) return null;
      method = userInfo.substring(0, split);
      password = userInfo.substring(split + 1);
      server = decoded.substring(at2 + 1, colon).replaceAll(RegExp(r'^\[|\]$'), '');
      port = int.tryParse(decoded.substring(colon + 1)) ?? 0;
    }
    if (server.isEmpty || port == 0) return null;

    return Outbound(
      tag: name ?? server,
      type: 'shadowsocks',
      json: {
        'type': 'shadowsocks',
        'server': server,
        'server_port': port,
        'method': method,
        'password': password,
      },
    );
  }

  /// `hysteria2://password@host:port?params#name`
  static Outbound? _hysteria2(String link) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty) return null;
    final q = uri.queryParameters;
    // Hysteria2 defaults to 443 when the link omits the port.
    final port = uri.hasPort ? uri.port : 443;

    return Outbound(
      tag: _fragment(uri) ?? uri.host,
      type: 'hysteria2',
      json: {
        'type': 'hysteria2',
        'server': uri.host,
        'server_port': port,
        'password': Uri.decodeComponent(uri.userInfo),
        if ((q['obfs'] ?? '').isNotEmpty)
          'obfs': {'type': q['obfs'], 'password': q['obfs-password'] ?? ''},
        'tls': _tls(
          enabled: true,
          serverName: q['sni'] ?? uri.host,
          alpn: q['alpn'] ?? '',
          fingerprint: '',
          insecure: q['insecure'] == '1',
        ),
      },
    );
  }

  /// `tuic://uuid:password@host:port?params#name`
  static Outbound? _tuic(String link) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty || uri.port == 0) return null;
    final userInfo = Uri.decodeComponent(uri.userInfo);
    final split = userInfo.indexOf(':');
    if (split < 0) return null;
    final q = uri.queryParameters;

    return Outbound(
      tag: _fragment(uri) ?? uri.host,
      type: 'tuic',
      json: {
        'type': 'tuic',
        'server': uri.host,
        'server_port': uri.port,
        'uuid': userInfo.substring(0, split),
        'password': userInfo.substring(split + 1),
        if ((q['congestion_control'] ?? '').isNotEmpty)
          'congestion_control': q['congestion_control'],
        if ((q['udp_relay_mode'] ?? '').isNotEmpty) 'udp_relay_mode': q['udp_relay_mode'],
        'tls': _tls(
          enabled: true,
          serverName: q['sni'] ?? uri.host,
          alpn: q['alpn'] ?? '',
          fingerprint: '',
          insecure: q['allow_insecure'] == '1',
        ),
      },
    );
  }

  /// `hysteria://host:port?auth=…&peer=…&upmbps=…&downmbps=…#name`
  ///
  /// Version 1, which puts the credential in the query rather than the userinfo.
  /// Superseded by hysteria2 but still what a number of servers run.
  static Outbound? _hysteria(String link) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty || uri.port == 0) return null;
    final q = uri.queryParameters;

    return Outbound(
      tag: _fragment(uri) ?? uri.host,
      type: 'hysteria',
      json: {
        'type': 'hysteria',
        'server': uri.host,
        'server_port': uri.port,
        if ((q['auth'] ?? '').isNotEmpty) 'auth_str': q['auth'],
        // Not optional, whatever the link says. sing-box refuses to build a
        // hysteria v1 outbound with no upload speed, and every server shares one
        // config — so one link that omits it would stop the tunnel starting at all,
        // for every other server too.
        'up_mbps': _speedOr(q['upmbps'], _defaultUpMbps),
        'down_mbps': _speedOr(q['downmbps'], _defaultDownMbps),
        if ((q['obfs'] ?? '').isNotEmpty) 'obfs': q['obfs'],
        'tls': _tls(
          enabled: true,
          // `peer` is hysteria's own spelling of the server name.
          serverName: q['peer'] ?? q['sni'] ?? uri.host,
          alpn: q['alpn'] ?? '',
          fingerprint: '',
          insecure: q['insecure'] == '1',
        ),
      },
    );
  }

  /// Conservative stand-ins for hysteria v1's mandatory bandwidth hints.
  ///
  /// They tune its congestion control rather than cap anything, so being under the
  /// real link speed costs some throughput; being absent costs the whole tunnel.
  static const _defaultUpMbps = 10;
  static const _defaultDownMbps = 50;

  static int _speedOr(String? value, int fallback) {
    final parsed = int.tryParse(value ?? '');
    return parsed != null && parsed > 0 ? parsed : fallback;
  }

  /// `anytls://password@host:port?sni=…#name`
  static Outbound? _anytls(String link) {
    final uri = Uri.parse(link);
    final password = Uri.decodeComponent(uri.userInfo);
    if (uri.host.isEmpty || uri.port == 0 || password.isEmpty) return null;
    final q = uri.queryParameters;

    return Outbound(
      tag: _fragment(uri) ?? uri.host,
      type: 'anytls',
      json: {
        'type': 'anytls',
        'server': uri.host,
        'server_port': uri.port,
        // A password of `user:pass` form carries a username anytls does not use.
        'password': password.contains(':') ? password.split(':').last : password,
        // anytls is TLS by definition, like trojan.
        'tls': _tls(
          enabled: true,
          serverName: q['sni'] ?? uri.host,
          alpn: q['alpn'] ?? '',
          fingerprint: q['fp'] ?? '',
          insecure: q['insecure'] == '1' || q['allowInsecure'] == '1',
        ),
      },
    );
  }

  /// `socks://base64(user:pass)@host:port#name`, or with the credentials in plain.
  ///
  /// No TLS and no obfuscation — this is a bare SOCKS5 hop. Worth supporting
  /// because it is how a proxy on the local network or another device is reached.
  static Outbound? _socks(String link) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty || uri.port == 0) return null;

    var username = '';
    var password = '';
    if (uri.userInfo.isNotEmpty) {
      // v2rayN base64s the whole userinfo; other clients leave it readable.
      final raw = uri.userInfo.contains(':')
          ? Uri.decodeComponent(uri.userInfo)
          : (_decodeBase64(uri.userInfo) ?? '');
      final split = raw.indexOf(':');
      if (split >= 0) {
        username = raw.substring(0, split);
        password = raw.substring(split + 1);
      }
    }

    return Outbound(
      tag: _fragment(uri) ?? uri.host,
      type: 'socks',
      json: {
        'type': 'socks',
        'server': uri.host,
        'server_port': uri.port,
        'version': '5',
        if (username.isNotEmpty) 'username': username,
        if (password.isNotEmpty) 'password': password,
      },
    );
  }

  /// Whether this server can only be run by the Xray core.
  ///
  /// `pqv` carries a post-quantum REALITY verification key (ML-DSA-65). sing-box has
  /// no field for it even in v1.14, and silently dropping it produces a config that
  /// validates and then fails with an opaque "reality verification failed".
  static bool _requiresXray(Map<String, String> q) => (q['pqv'] ?? '').isNotEmpty;

  /// Link features neither bundled core can honour.
  ///
  /// Empty today. Cosmetic Xray-only extras such as `spx` are not listed here:
  /// ignoring them still leaves a working connection.
  static List<String> _unsupportedFeatures(Map<String, String> q) => const [];

  // ---- shared pieces -----------------------------------------------------

  static Map<String, Object?> _tls({
    required bool enabled,
    required String serverName,
    required String alpn,
    required String fingerprint,
    required bool insecure,
  }) => {
    'enabled': enabled,
    if (serverName.isNotEmpty) 'server_name': serverName,
    if (alpn.isNotEmpty)
      'alpn': alpn.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
    if (fingerprint.isNotEmpty) 'utls': {'enabled': true, 'fingerprint': fingerprint},
    if (insecure) 'insecure': true,
  };

  /// sing-box only wants a `transport` block for non-TCP networks; emitting one for
  /// plain TCP is rejected as an unknown transport type.
  static Map<String, Object?>? _transport({
    required String network,
    required String path,
    required String host,
    required String serviceName,
  }) {
    switch (network) {
      case 'ws':
        return {
          'type': 'ws',
          if (path.isNotEmpty) 'path': path,
          if (host.isNotEmpty) 'headers': {'Host': host},
        };
      case 'grpc':
        return {'type': 'grpc', if (serviceName.isNotEmpty) 'service_name': serviceName};
      case 'http' || 'h2':
        return {
          'type': 'http',
          if (host.isNotEmpty) 'host': host.split(',').map((e) => e.trim()).toList(),
          if (path.isNotEmpty) 'path': path,
        };
      case 'httpupgrade':
        return {
          'type': 'httpupgrade',
          if (host.isNotEmpty) 'host': host,
          if (path.isNotEmpty) 'path': path,
        };
      default:
        return null;
    }
  }

  static String? _fragment(Uri uri) {
    final fragment = uri.fragment;
    if (fragment.isEmpty) return null;
    return _decodeFragment(fragment);
  }

  static String _decodeFragment(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  static bool _looksBase64(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    // A subscription body that already contains a scheme is plain text.
    if (trimmed.contains('://')) return false;
    return RegExp(r'^[A-Za-z0-9+/=_\-\s]+$').hasMatch(trimmed);
  }

  static String? _decodeBase64(String value) {
    var normalized = value
        .trim()
        .replaceAll(RegExp(r'\s'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    // Providers routinely strip the padding; base64Decode insists on it.
    normalized = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
    try {
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

/// Builds a server from hand-written sing-box JSON.
///
/// Deliberately takes a single *outbound*, not a whole config. An outbound stays a
/// server like any other: it joins the selector, gets measured, and obeys the routing
/// rules. A pasted full config would have to bypass all of that, and the app would
/// then be showing rules it is not applying.
class CustomOutbound {
  const CustomOutbound._();

  /// Type names that describe the config's plumbing rather than a server.
  static const _notServers = {'direct', 'block', 'dns', 'selector', 'urltest'};

  /// Returns the parsed outbound, or throws [FormatException] with a reason.
  ///
  /// A whole config is accepted as a convenience: the first entry in `outbounds`
  /// that actually names a server is taken.
  static Outbound parse(String source, {String? name}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw FormatException('Not valid JSON: ${e.message}');
    }
    if (decoded is! Map) throw const FormatException('Expected a JSON object');

    var node = decoded.cast<String, Object?>();
    if (node['outbounds'] case final List list) {
      final server = list.whereType<Map>().cast<Map<String, Object?>>().where((e) {
        final type = e['type'];
        return type is String && !_notServers.contains(type);
      });
      if (server.isEmpty) {
        throw const FormatException('That config contains no server outbound');
      }
      node = server.first;
    }

    final type = node['type'];
    if (type is! String || type.isEmpty) {
      throw const FormatException('Outbound is missing a "type"');
    }
    if (_notServers.contains(type)) {
      throw FormatException('"$type" is not a server outbound');
    }

    final tag = (name?.trim().isNotEmpty ?? false)
        ? name!.trim()
        : (node['tag'] as String?)?.trim().isNotEmpty == true
        ? (node['tag'] as String).trim()
        : '${node['server'] ?? type}';

    return Outbound(tag: tag, type: type, json: {...node, 'tag': tag});
  }
}
