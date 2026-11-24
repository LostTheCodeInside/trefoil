import 'package:yaml/yaml.dart';

import 'outbound.dart';
import 'server_check.dart';
import 'share_link.dart';

/// Reads the `proxies:` list out of a Clash or Clash.Meta configuration.
///
/// A good number of providers ship only this. Their subscription URL returns a YAML
/// document rather than the list of share links every other client format uses, and
/// without this the app simply cannot import them — there is no workaround from the
/// user's side.
///
/// The same tolerance the link parsers have applies here: a proxy whose type is
/// unknown, or which is missing something it cannot work without, is skipped rather
/// than thrown over. One unsupported entry in a two-hundred-server list must not
/// cost the other hundred and ninety-nine.
class ClashConfig {
  const ClashConfig._();

  /// Whether [body] is worth handing to [parse].
  ///
  /// Deliberately narrow: a `proxies:` key at the start of a line. Sniffing for
  /// YAML in general would claim bodies that are really something else, and the
  /// cost of a wrong answer here is an import that reports nothing found.
  static bool looksLikeClash(String body) =>
      RegExp(r'^\s{0,4}proxies\s*:', multiLine: true).hasMatch(body);

  /// Parses every proxy the document holds. Returns an empty list when it holds
  /// none, or when the YAML does not parse at all.
  static List<Outbound> parse(String body) {
    final Object? document;
    try {
      document = loadYaml(body);
    } on YamlException {
      return const [];
    }
    if (document is! Map) return const [];
    final proxies = document['proxies'];
    if (proxies is! List) return const [];

    final out = <Outbound>[];
    for (final entry in proxies) {
      if (entry is! Map) continue;
      // YamlMap is a Map but not a Map<String, Object?>; going through a plain map
      // once here keeps every field access below ordinary.
      final proxy = <String, Object?>{
        for (final key in entry.keys) key.toString(): _plain(entry[key]),
      };
      final parsed = _proxy(proxy);
      if (parsed != null) out.add(parsed);
    }
    return out;
  }

  /// Recursively converts YamlMap/YamlList into plain Dart collections.
  static Object? _plain(Object? value) => switch (value) {
    YamlMap map => {for (final key in map.keys) key.toString(): _plain(map[key])},
    YamlList list => [for (final item in list) _plain(item)],
    _ => value,
  };

  // ---- one proxy ---------------------------------------------------------

  static Outbound? _proxy(Map<String, Object?> p) {
    final server = _str(p['server']);
    // Out of range is as unusable as absent, and unlike that it fails the whole config.
    final port = _int(p['port']);
    if (server.isEmpty || port < 1 || port > 65535) return null;

    final name = _str(p['name']).isEmpty ? server : _str(p['name']);
    final type = _str(p['type']).toLowerCase();

    final json = switch (type) {
      'ss' || 'shadowsocks' => _shadowsocks(p, server, port),
      'vmess' => _vmess(p, server, port),
      'vless' => _vless(p, server, port),
      'trojan' => _trojan(p, server, port),
      'hysteria2' || 'hy2' => _hysteria2(p, server, port),
      'hysteria' => _hysteria(p, server, port),
      'tuic' => _tuic(p, server, port),
      'anytls' => _anytls(p, server, port),
      'socks5' || 'socks' => _socks(p, server, port),
      'http' || 'https' => _http(p, server, port),
      // ssr, ssh, wireguard, snell and the rest: either the bundled cores cannot
      // run them, or they are not an outbound in sing-box at all. Skipped, so the
      // rest of the list still imports.
      _ => null,
    };
    if (json == null) return null;

    final built = {...json};
    final chain = <Map<String, Object?>>[];
    final unsupported = <String>[];
    _applyPlugin(p, built, chain, unsupported, server, port);
    if (const {'vmess', 'vless', 'trojan'}.contains(type)) {
      final network = _str(p['network']).toLowerCase();
      // Imported as plain TCP, these would be servers that look fine and never answer.
      if (!const {'', 'tcp', 'raw', 'ws', 'grpc', 'h2', 'http', 'httpupgrade'}.contains(network)) {
        unsupported.add('${ServerProblem(ServerProblem.transport, network)}');
      }
    }

    return Outbound(
      tag: name,
      type: built['type'] as String,
      json: {...built, 'tag': name},
      chain: chain,
      unsupported: unsupported,
    );
  }

  /// Turns a Clash `plugin` into whatever sing-box calls the same thing.
  ///
  /// sing-box has exactly two SIP003 plugins — `obfs-local` and `v2ray-plugin`. An
  /// unrecognised name is not a field it ignores: it is `plugin not found` at start,
  /// fatal for the *whole config* rather than for the one server. A single such entry
  /// in a two-hundred-proxy subscription used to leave the tunnel unable to start at
  /// all, so anything not understood here is marked unsupported instead, which keeps
  /// it out of the generated config and says why in the UI.
  static void _applyPlugin(
    Map<String, Object?> p,
    Map<String, Object?> json,
    List<Map<String, Object?>> chain,
    List<String> unsupported,
    String server,
    int port,
  ) {
    final name = _str(p['plugin']).toLowerCase();
    if (name.isEmpty) return;
    final options = _pluginOptions(p);
    switch (name) {
      case 'obfs' || 'simple-obfs':
        json['plugin'] = 'obfs-local';
        // Clash says `mode` and `host`; the plugin only answers to its own names, and
        // ignores any other.
        final renamed = {
          for (final MapEntry(:key, :value) in options.entries)
            switch (key) {
              'mode' => 'obfs',
              'host' => 'obfs-host',
              _ => key,
            }: value,
        };
        if (renamed.isNotEmpty) json['plugin_opts'] = _joined(renamed);
      case 'v2ray-plugin':
        json['plugin'] = 'v2ray-plugin';
        final known = {
          for (final MapEntry(:key, :value) in options.entries)
            if (const {'mode', 'host', 'path'}.contains(key))
              key: value
            // Its presence is what turns it on, whatever it is set to.
            else if (key == 'tls' && value == 'true')
              key: ''
            // A number, where Clash has a switch.
            else if (key == 'mux')
              key: switch (value) {
                'true' => '1',
                'false' => '0',
                _ => value,
              },
        };
        if (known.isNotEmpty) json['plugin_opts'] = _joined(known);
      case 'shadow-tls':
        _shadowTls(p, json, chain, server, port);
      default:
        unsupported.add('${ServerProblem(ServerProblem.plugin, name)}');
    }
  }

  /// ShadowTLS: one proxy in Clash, two outbounds in sing-box.
  ///
  /// The `shadowtls` outbound holds the address and does the handshake; the
  /// Shadowsocks one keeps only its cipher and password and dials through it, which
  /// is why the address is taken off it here. `host` from the plugin options is the
  /// site being impersonated, not somewhere anything connects to — it belongs in
  /// `server_name`, and confusing the two produces a config that connects to the
  /// wrong machine.
  static void _shadowTls(
    Map<String, Object?> p,
    Map<String, Object?> json,
    List<Map<String, Object?>> chain,
    String server,
    int port,
  ) {
    final options = p['plugin-opts'];
    final opts = options is Map ? options.cast<String, Object?>() : const <String, Object?>{};
    final host = _str(opts['host']);
    final version = switch (_int(opts['version'])) {
      1 => 1,
      2 => 2,
      // Three is both the default and what practically every provider ships; an
      // out-of-range number is a typo rather than a fourth version.
      _ => 3,
    };
    chain.add({
      'type': 'shadowtls',
      'server': server,
      'server_port': port,
      'version': version,
      if (_str(opts['password']).isNotEmpty) 'password': _str(opts['password']),
      'tls': {
        'enabled': true,
        if (host.isNotEmpty) 'server_name': host,
        if (opts['alpn'] case final List alpn when alpn.isNotEmpty)
          'alpn': [for (final item in alpn) _str(item)],
      },
    });
    json
      ..remove('server')
      ..remove('server_port');
  }

  static Map<String, Object?> _shadowsocks(Map<String, Object?> p, String server, int port) => {
    'type': 'shadowsocks',
    'server': server,
    'server_port': port,
    'method': _str(p['cipher']),
    'password': _str(p['password']),
  };

  static Map<String, Object?> _vmess(Map<String, Object?> p, String server, int port) {
    final json = <String, Object?>{
      'type': 'vmess',
      'server': server,
      'server_port': port,
      'uuid': _str(p['uuid']),
      'security': _str(p['cipher']).isEmpty ? 'auto' : _str(p['cipher']),
      if (_int(p['alterId']) > 0) 'alter_id': _int(p['alterId']),
    };
    _addTransport(json, p);
    // Clash treats TLS as an explicit flag; a websocket vmess without it is plain.
    if (_bool(p['tls'])) json['tls'] = _tls(p, server);
    return json;
  }

  static Map<String, Object?> _vless(Map<String, Object?> p, String server, int port) {
    final json = <String, Object?>{
      'type': 'vless',
      'server': server,
      'server_port': port,
      'uuid': _str(p['uuid']),
      if (_str(p['flow']).isNotEmpty) 'flow': _str(p['flow']),
    };
    _addTransport(json, p);
    // VLESS is only meaningful over TLS or REALITY, and providers routinely leave
    // the flag off when REALITY options are present.
    final reality = p['reality-opts'];
    if (_bool(p['tls']) || reality is Map) {
      final tls = _tls(p, server);
      if (reality is Map) {
        final options = reality.cast<String, Object?>();
        tls['reality'] = {
          'enabled': true,
          if (_str(options['public-key']).isNotEmpty)
            'public_key': ServerCheck.realityKey(_str(options['public-key'])),
          if (_str(options['short-id']).isNotEmpty) 'short_id': _str(options['short-id']),
        };
        // REALITY without a uTLS fingerprint is trivially distinguishable, which is
        // the one thing it exists to prevent.
        final fingerprint = ServerCheck.fingerprint(_str(p['client-fingerprint']));
        tls['utls'] = {
          'enabled': true,
          'fingerprint': fingerprint.isEmpty ? 'chrome' : fingerprint,
        };
      }
      json['tls'] = tls;
    }
    return json;
  }

  static Map<String, Object?> _trojan(Map<String, Object?> p, String server, int port) {
    final json = <String, Object?>{
      'type': 'trojan',
      'server': server,
      'server_port': port,
      'password': _str(p['password']),
      // Trojan is TLS by definition; Clash omits the flag.
      'tls': _tls(p, server),
    };
    _addTransport(json, p);
    return json;
  }

  static Map<String, Object?> _hysteria2(Map<String, Object?> p, String server, int port) => {
    'type': 'hysteria2',
    'server': server,
    'server_port': port,
    if (ShareLink.portRanges(_str(p['ports'])) case final ranges when ranges.isNotEmpty)
      'server_ports': ranges,
    'password': _str(p['password']),
    if (_mbps(p['up']) > 0) 'up_mbps': _mbps(p['up']),
    if (_mbps(p['down']) > 0) 'down_mbps': _mbps(p['down']),
    if (_str(p['obfs']).isNotEmpty)
      'obfs': {'type': _str(p['obfs']), 'password': _str(p['obfs-password'])},
    'tls': _tls(p, server),
  };

  static Map<String, Object?> _hysteria(Map<String, Object?> p, String server, int port) => {
    'type': 'hysteria',
    'server': server,
    'server_port': port,
    if (ShareLink.portRanges(_str(p['ports'])) case final ranges when ranges.isNotEmpty)
      'server_ports': ranges,
    // Clash spells this either way depending on its age.
    'auth_str': _str(p['auth-str']).isEmpty ? _str(p['auth_str']) : _str(p['auth-str']),
    // Emitted even when the document omits them: sing-box refuses to build a
    // hysteria v1 outbound without an upload speed, and every server in the
    // subscription shares one config — so one such entry would stop the tunnel
    // starting for all of them.
    'up_mbps': _mbps(p['up']) > 0 ? _mbps(p['up']) : _defaultUpMbps,
    'down_mbps': _mbps(p['down']) > 0 ? _mbps(p['down']) : _defaultDownMbps,
    if (_str(p['obfs']).isNotEmpty) 'obfs': _str(p['obfs']),
    'tls': _tls(p, server),
  };

  /// Conservative stand-ins for hysteria v1's mandatory bandwidth hints. They tune
  /// its congestion control rather than cap anything.
  static const _defaultUpMbps = 10;
  static const _defaultDownMbps = 50;

  static Map<String, Object?>? _tuic(Map<String, Object?> p, String server, int port) {
    // TUIC v4 authenticated with a token; sing-box implements v5 only, and a v4
    // entry imported as v5 would fail the handshake with nothing explaining why.
    if (_str(p['uuid']).isEmpty) return null;
    return {
      'type': 'tuic',
      'server': server,
      'server_port': port,
      'uuid': _str(p['uuid']),
      'password': _str(p['password']),
      if (_str(p['congestion-controller']).isNotEmpty)
        'congestion_control': _str(p['congestion-controller']),
      if (_str(p['udp-relay-mode']).isNotEmpty) 'udp_relay_mode': _str(p['udp-relay-mode']),
      'tls': _tls(p, server),
    };
  }

  static Map<String, Object?> _anytls(Map<String, Object?> p, String server, int port) => {
    'type': 'anytls',
    'server': server,
    'server_port': port,
    'password': _str(p['password']),
    'tls': _tls(p, server),
  };

  static Map<String, Object?> _socks(Map<String, Object?> p, String server, int port) => {
    'type': 'socks',
    'server': server,
    'server_port': port,
    'version': '5',
    if (_str(p['username']).isNotEmpty) 'username': _str(p['username']),
    if (_str(p['password']).isNotEmpty) 'password': _str(p['password']),
  };

  static Map<String, Object?> _http(Map<String, Object?> p, String server, int port) => {
    'type': 'http',
    'server': server,
    'server_port': port,
    if (_str(p['username']).isNotEmpty) 'username': _str(p['username']),
    if (_str(p['password']).isNotEmpty) 'password': _str(p['password']),
    if (_bool(p['tls'])) 'tls': _tls(p, server),
  };

  // ---- shared pieces -----------------------------------------------------

  /// sing-box wants no `transport` block for plain TCP; emitting one is an error.
  static void _addTransport(Map<String, Object?> json, Map<String, Object?> p) {
    final network = _str(p['network']).toLowerCase();
    final transport = switch (network) {
      'ws' => _ws(p),
      'grpc' => {
        'type': 'grpc',
        if (_opt(p, 'grpc-opts', 'grpc-service-name') case final name when name.isNotEmpty)
          'service_name': name,
      },
      'h2' || 'http' => _h2(p),
      'httpupgrade' => {
        'type': 'httpupgrade',
        if (_opt(p, 'httpupgrade-opts', 'host') case final host when host.isNotEmpty) 'host': host,
        if (_opt(p, 'httpupgrade-opts', 'path') case final path when path.isNotEmpty) 'path': path,
      },
      _ => null,
    };
    if (transport != null) json['transport'] = transport;
  }

  static Map<String, Object?> _ws(Map<String, Object?> p) {
    final options = p['ws-opts'];
    final map = options is Map ? options.cast<String, Object?>() : const <String, Object?>{};
    final headers = map['headers'];
    final host = headers is Map ? _headerHost(headers.cast<String, Object?>()) : '';
    return {
      'type': 'ws',
      if (_str(map['path']).isNotEmpty) 'path': _str(map['path']),
      if (host.isNotEmpty) 'headers': {'Host': host},
      // Clash's early data support maps onto sing-box's two fields directly.
      if (_int(map['max-early-data']) > 0) 'max_early_data': _int(map['max-early-data']),
      if (_str(map['early-data-header-name']).isNotEmpty)
        'early_data_header_name': _str(map['early-data-header-name']),
    };
  }

  static Map<String, Object?> _h2(Map<String, Object?> p) {
    final options = p['h2-opts'];
    final map = options is Map ? options.cast<String, Object?>() : const <String, Object?>{};
    final host = map['host'];
    return {
      'type': 'http',
      if (host is List && host.isNotEmpty) 'host': [for (final item in host) _str(item)],
      if (host is String && host.isNotEmpty) 'host': [host],
      if (_str(map['path']).isNotEmpty) 'path': _str(map['path']),
    };
  }

  /// The Host header, whichever capitalisation the document used.
  static String _headerHost(Map<String, Object?> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'host') return _str(entry.value);
    }
    return '';
  }

  static String _opt(Map<String, Object?> p, String block, String key) {
    final options = p[block];
    return options is Map ? _str(options.cast<String, Object?>()[key]) : '';
  }

  static Map<String, Object?> _tls(Map<String, Object?> p, String server) {
    // Clash carries the name under either key depending on the protocol.
    final name = _str(p['servername']).isNotEmpty ? _str(p['servername']) : _str(p['sni']);
    final alpn = p['alpn'];
    final fingerprint = ServerCheck.fingerprint(_str(p['client-fingerprint']));
    return {
      'enabled': true,
      'server_name': name.isEmpty ? server : name,
      if (alpn is List && alpn.isNotEmpty) 'alpn': [for (final item in alpn) _str(item)],
      if (alpn is String && alpn.isNotEmpty) 'alpn': [alpn],
      if (fingerprint.isNotEmpty) 'utls': {'enabled': true, 'fingerprint': fingerprint},
      // Carried through rather than dropped: the document is the user's own, and
      // silently turning verification back on would break servers that work today.
      if (_bool(p['skip-cert-verify'])) 'insecure': true,
    };
  }

  /// The plugin's options that hold a single value. Clash nests a map in some, such as
  /// websocket headers, which a plugin has no way to be told.
  static Map<String, String> _pluginOptions(Map<String, Object?> p) {
    final options = p['plugin-opts'];
    if (options is! Map) return const {};
    return {
      for (final MapEntry(:key, :value) in options.entries)
        if (value is! Map && value is! List && _str(value).isNotEmpty) '$key': _str(value),
    };
  }

  /// sing-box takes a plugin's options as one string.
  static String _joined(Map<String, String> options) =>
      [for (final MapEntry(:key, :value) in options.entries) value.isEmpty ? key : '$key=$value']
          .join(';');

  // ---- scalars -----------------------------------------------------------

  static String _str(Object? value) => value?.toString().trim() ?? '';

  static int _int(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v.trim()) ?? 0,
    _ => 0,
  };

  static bool _bool(Object? value) => switch (value) {
    final bool v => v,
    final String v => v.toLowerCase() == 'true',
    _ => false,
  };

  /// Clash writes bandwidth as a bare number or as `"30 Mbps"`. Only the leading
  /// number is meaningful — sing-box takes megabits, and so does Clash.
  static int _mbps(Object? value) {
    if (value is num) return value.toInt();
    final match = RegExp(r'\d+').firstMatch(_str(value));
    return match == null ? 0 : int.parse(match.group(0)!);
  }
}
