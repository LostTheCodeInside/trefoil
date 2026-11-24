import 'dart:convert';

/// Why a server cannot be used, as a code and what it is about.
///
/// Stored with the server and shown in the user's language, so it is neither prose nor
/// a closed enum: a backup may come from a version that knows a reason this one does
/// not, and that one is shown as it is written.
class ServerProblem {
  const ServerProblem(this.code, [this.detail = '']);

  /// A SIP003 plugin neither core has.
  static const plugin = 'plugin';

  /// A way of carrying the connection that the core for this protocol does not have.
  static const transport = 'transport';

  /// Certificate checks switched off, on a server only Xray can run: it dropped that.
  static const insecureTls = 'insecure-tls';

  static const port = 'port';
  static const cipher = 'cipher';
  static const flow = 'flow';
  static const key = 'key';
  static const fingerprint = 'fingerprint';
  static const obfs = 'obfs';
  static const congestion = 'congestion';
  static const path = 'path';

  final String code;
  final String detail;

  /// Anything without a code is taken as a sentence of its own, which is what servers
  /// were stored with before codes existed.
  factory ServerProblem.parse(String stored) {
    final legacy = RegExp(r'^the (.+) plugin$').firstMatch(stored);
    if (legacy != null) return ServerProblem(plugin, legacy.group(1)!);
    final split = stored.indexOf(':');
    final code = split < 0 ? stored : stored.substring(0, split);
    if (!RegExp(r'^[a-z-]+$').hasMatch(code)) return ServerProblem('', stored);
    return ServerProblem(code, split < 0 ? '' : stored.substring(split + 1));
  }

  @override
  String toString() => detail.isEmpty ? code : '$code:$detail';
}

/// Finds what sing-box would refuse in a server.
///
/// Every server goes into one config, and sing-box rejects the whole of it over one
/// value it does not accept: a subscription with a single mistyped cipher left the
/// tunnel unable to start for all the others. So each is held to what the core checks
/// before it goes in, and one that fails is kept, marked and left out.
///
/// Only what the core refuses at start. A wrong password or an unreachable host is a
/// connection that fails, which is the server's own business.
class ServerCheck {
  const ServerCheck._();

  /// The fingerprints uTLS has, as sing-box names them.
  static const fingerprints = {
    'chrome',
    'firefox',
    'edge',
    'safari',
    '360',
    'qq',
    'ios',
    'android',
    'random',
    'randomized',
    'chrome_psk',
    'chrome_psk_shuffle',
    'chrome_padding_psk_shuffle',
    'chrome_pq',
    'chrome_pq_psk',
  };

  static const _vmessSecurity = {
    'auto',
    'none',
    'zero',
    'aes-128-cfb',
    'aes-128-gcm',
    'chacha20-poly1305',
  };

  static const _shadowsocksMethods = {
    'none',
    'aes-128-gcm',
    'aes-192-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
    'xchacha20-ietf-poly1305',
    'aes-128-ctr',
    'aes-192-ctr',
    'aes-256-ctr',
    'aes-128-cfb',
    'aes-192-cfb',
    'aes-256-cfb',
    'rc4-md5',
    'chacha20-ietf',
    'xchacha20',
  };

  /// Key length in bytes, which Shadowsocks 2022 insists on exactly.
  static const _shadowsocks2022 = {
    '2022-blake3-aes-128-gcm': 16,
    '2022-blake3-aes-256-gcm': 32,
    '2022-blake3-chacha20-poly1305': 32,
  };

  static const _transports = {'ws', 'grpc', 'http', 'httpupgrade', 'quic'};

  /// The first thing sing-box would refuse in [json] and the [chain] it dials through,
  /// or null.
  static ServerProblem? of(
    Map<String, Object?> json, {
    List<Map<String, Object?>> chain = const [],
  }) {
    if (json['type'] == 'wireguard') return _wireguard(json);
    // The address is on the link that dials out, when there is one.
    final address = chain.isEmpty ? json : chain.first;
    // Absent is fine here: some types have a default, and a range can stand in for it.
    if (address['server_port'] case final port? when !_isPort(port)) {
      return ServerProblem(ServerProblem.port, '$port');
    }
    return _protocol(json) ??
        _tls(json['tls']) ??
        (chain.isEmpty ? null : _tls(chain.first['tls'])) ??
        _transport(json['transport']);
  }

  static bool _isPort(Object? value) => value is int && value > 0 && value <= 65535;

  static ServerProblem? _protocol(Map<String, Object?> json) {
    switch (json['type']) {
      case 'vmess':
        final security = json['security'] ?? 'auto';
        if (!_vmessSecurity.contains(security)) {
          return ServerProblem(ServerProblem.cipher, '$security');
        }
      case 'vless':
        final flow = json['flow'] ?? '';
        if (flow != '' && flow != 'xtls-rprx-vision') {
          return ServerProblem(ServerProblem.flow, '$flow');
        }
      case 'shadowsocks':
        return _shadowsocks(json);
      case 'tuic':
        if (!_isUuid('${json['uuid'] ?? ''}')) return const ServerProblem(ServerProblem.key);
        final congestion = json['congestion_control'] ?? '';
        if (!const {'', 'cubic', 'new_reno', 'bbr'}.contains(congestion)) {
          return ServerProblem(ServerProblem.congestion, '$congestion');
        }
      case 'hysteria2':
        if (json['obfs'] case final Map obfs) {
          final type = obfs['type'];
          if (type != 'salamander' && type != 'gecko') {
            return ServerProblem(ServerProblem.obfs, '$type');
          }
          if ('${obfs['password'] ?? ''}'.isEmpty) return const ServerProblem(ServerProblem.key);
        }
    }
    return null;
  }

  static ServerProblem? _shadowsocks(Map<String, Object?> json) {
    final method = '${json['method'] ?? ''}';
    final password = '${json['password'] ?? ''}';
    if (_shadowsocks2022[method] case final length?) {
      final keys = [for (final key in password.split(':')) _base64(key)];
      return keys.every((key) => key?.length == length)
          ? null
          : const ServerProblem(ServerProblem.key);
    }
    if (!_shadowsocksMethods.contains(method)) return ServerProblem(ServerProblem.cipher, method);
    if (method != 'none' && password.isEmpty) return const ServerProblem(ServerProblem.key);
    if (json['plugin'] == 'obfs-local') {
      final mode = RegExp(r'(?:^|;)obfs=([^;]*)').firstMatch('${json['plugin_opts'] ?? ''}');
      if (mode != null && !const {'http', 'tls'}.contains(mode.group(1))) {
        return ServerProblem(ServerProblem.obfs, mode.group(1)!);
      }
    }
    return null;
  }

  static ServerProblem? _tls(Object? tls) {
    if (tls is! Map) return null;
    if (tls['utls'] case final Map utls when utls['enabled'] == true) {
      final fingerprint = utls['fingerprint'] ?? '';
      if (fingerprint != '' && !fingerprints.contains(fingerprint)) {
        return ServerProblem(ServerProblem.fingerprint, '$fingerprint');
      }
    }
    if (tls['reality'] case final Map reality when reality['enabled'] == true) {
      final publicKey = '${reality['public_key'] ?? ''}';
      final shortId = '${reality['short_id'] ?? ''}';
      if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(publicKey) ||
          // Longer than this and the core does not refuse it, it crashes.
          !RegExp(r'^([0-9a-fA-F]{2}){0,8}$').hasMatch(shortId)) {
        return const ServerProblem(ServerProblem.key);
      }
    }
    return null;
  }

  static ServerProblem? _transport(Object? transport) {
    if (transport is! Map) return null;
    final type = transport['type'];
    if (!_transports.contains(type)) return ServerProblem(ServerProblem.transport, '$type');
    final path = '${transport['path'] ?? ''}';
    // Parsed as a URL path, where a stray percent sign is an error.
    if (RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(path)) {
      return ServerProblem(ServerProblem.path, path);
    }
    return null;
  }

  static ServerProblem? _wireguard(Map<String, Object?> json) {
    final peers = json['peers'];
    if (peers is! List || peers.isEmpty) return const ServerProblem(ServerProblem.port);
    if (_base64('${json['private_key'] ?? ''}')?.length != 32) {
      return const ServerProblem(ServerProblem.key);
    }
    for (final peer in peers) {
      if (peer is! Map) return const ServerProblem(ServerProblem.key);
      if (!_isPort(peer['port'])) return ServerProblem(ServerProblem.port, '${peer['port'] ?? ''}');
      if (_base64('${peer['public_key'] ?? ''}')?.length != 32) {
        return const ServerProblem(ServerProblem.key);
      }
      final shared = '${peer['pre_shared_key'] ?? ''}';
      if (shared.isNotEmpty && _base64(shared)?.length != 32) {
        return const ServerProblem(ServerProblem.key);
      }
    }
    return null;
  }

  static List<int>? _base64(String value) {
    try {
      return base64.decode(value);
    } on FormatException {
      return null;
    }
  }

  /// The forms sing-box's own parser takes: with dashes, without, in braces, as a URN.
  static bool _isUuid(String value) => RegExp(
    r'^(urn:uuid:)?\{?[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\}?$',
    caseSensitive: false,
  ).hasMatch(value);

  /// A fingerprint as a link spells it, in a name the core has.
  ///
  /// It only decides which browser the handshake looks like, so one nobody knows is
  /// replaced rather than held against the server. Empty when the link asks for none.
  static String fingerprint(String value) {
    final name = value.trim().toLowerCase();
    if (name.isEmpty || name == 'unsafe') return '';
    return fingerprints.contains(name) ? name : 'chrome';
  }

  /// A REALITY public key in the alphabet the core reads, without padding.
  static String realityKey(String value) =>
      value.trim().replaceAll('+', '-').replaceAll('/', '_').replaceAll(RegExp(r'=+$'), '');
}
