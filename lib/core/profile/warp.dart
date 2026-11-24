import 'dart:convert';
import 'dart:io';

/// A registered Cloudflare WARP account.
///
/// WARP is WireGuard underneath, and Cloudflare hands out free accounts to anyone
/// who asks. Registering one gives an exit through Cloudflare's network, which is
/// useful for two different reasons: as an extra hop when a proxy's datacenter IP is
/// blocked by a site, and as a plain exit of its own.
class WarpAccount {
  const WarpAccount({
    required this.privateKey,
    required this.peerPublicKey,
    required this.endpointHost,
    required this.endpointPort,
    required this.addressV4,
    required this.addressV6,
    required this.reserved,
    required this.registeredAt,
    this.accountId = '',
    this.token = '',
    this.licensed = false,
  });

  final String privateKey;
  final String peerPublicKey;
  final String endpointHost;
  final int endpointPort;
  final String addressV4;
  final String addressV6;

  /// Three bytes derived from the account's client id. WARP will not answer without
  /// them: they are how Cloudflare routes a packet back to the right account.
  final List<int> reserved;

  final DateTime registeredAt;

  /// Cloudflare's id for this registration, and the bearer token that authorises
  /// changes to it. Both are needed to attach a WARP+ licence later; without them
  /// the only way to upgrade would be to throw the account away and register again.
  final String accountId;
  final String token;

  /// True once a WARP+ licence has been accepted for this account.
  final bool licensed;

  WarpAccount copyWith({bool? licensed}) => WarpAccount(
    privateKey: privateKey,
    peerPublicKey: peerPublicKey,
    endpointHost: endpointHost,
    endpointPort: endpointPort,
    addressV4: addressV4,
    addressV6: addressV6,
    reserved: reserved,
    registeredAt: registeredAt,
    accountId: accountId,
    token: token,
    licensed: licensed ?? this.licensed,
  );

  Map<String, Object?> toJson() => {
    'privateKey': privateKey,
    'peerPublicKey': peerPublicKey,
    'endpointHost': endpointHost,
    'endpointPort': endpointPort,
    'addressV4': addressV4,
    'addressV6': addressV6,
    'reserved': reserved,
    'registeredAt': registeredAt.toIso8601String(),
    'accountId': accountId,
    'token': token,
    'licensed': licensed,
  };

  factory WarpAccount.fromJson(Map<String, Object?> map) => WarpAccount(
    privateKey: map['privateKey'] as String? ?? '',
    peerPublicKey: map['peerPublicKey'] as String? ?? '',
    endpointHost: map['endpointHost'] as String? ?? '',
    endpointPort: (map['endpointPort'] as num?)?.toInt() ?? 2408,
    addressV4: map['addressV4'] as String? ?? '',
    addressV6: map['addressV6'] as String? ?? '',
    reserved: (map['reserved'] as List? ?? []).map((e) => (e as num).toInt()).toList(),
    registeredAt: DateTime.tryParse(map['registeredAt'] as String? ?? '') ?? DateTime.now(),
    accountId: map['accountId'] as String? ?? '',
    token: map['token'] as String? ?? '',
    licensed: map['licensed'] as bool? ?? false,
  );

  /// The sing-box endpoint this account becomes.
  ///
  /// [host] and [port] override what registration handed back. Cloudflare answers on
  /// a wide range of addresses and ports, and which of them a given network leaves
  /// alone varies — so being able to point at another one is the difference between
  /// WARP working and not, on exactly the networks WARP is for.
  Map<String, Object?> toEndpoint({
    required String tag,
    String? detour,
    String host = '',
    int port = 0,
  }) => {
    'type': 'wireguard',
    'tag': tag,
    // WARP's own path out. Through the proxy it becomes a second hop, which is the
    // point when a site blocks the proxy's exit IP. Null means straight out, and it
    // has to be the absence of the field rather than a detour to `direct`: sing-box
    // refuses to dial through an empty direct outbound, since that is the same thing
    // written the long way round.
    if (detour != null && detour.isNotEmpty) 'detour': detour,
    // Cloudflare's tunnel does not carry a full 1500 bytes, and a too-large MTU
    // shows up as large requests hanging rather than failing.
    'mtu': 1280,
    'address': ['$addressV4/32', '$addressV6/128'],
    'private_key': privateKey,
    'peers': [
      {
        'address': host.trim().isEmpty ? endpointHost : host.trim(),
        'port': port > 0 ? port : endpointPort,
        'public_key': peerPublicKey,
        'allowed_ips': ['0.0.0.0/0', '::/0'],
        if (reserved.length == 3) 'reserved': reserved,
        'persistent_keepalive_interval': 25,
      },
    ],
  };
}

/// Registers free WARP accounts with Cloudflare.
class WarpRegistration {
  const WarpRegistration({
    required this.generateKeyPair,
    this.timeout = const Duration(seconds: 30),
  });

  /// Returns "privateKey\npublicKey", both base64.
  ///
  /// Injected rather than reached for directly so this file stays free of Flutter:
  /// the config it produces can then be generated and checked against the real
  /// sing-box binary on a desktop, with no device involved.
  final Future<String> Function() generateKeyPair;

  final Duration timeout;

  /// The client build Cloudflare's own app reports. The endpoint is undocumented and
  /// rejects requests that do not look like the app.
  static const _clientVersion = 'a-6.30-3596';
  static const _endpoint = 'https://api.cloudflareclient.com/v0a2158/reg';

  /// Registration returns port 0; 2408 is the port Cloudflare's clients actually use.
  static const _wireGuardPort = 2408;

  Future<WarpAccount> register() async {
    // The key pair is generated by the Go core rather than in Dart: it is a vetted
    // implementation, and the private key crosses into the app exactly once.
    final pair = await generateKeyPair();
    final parts = pair.split('\n');
    if (parts.length != 2 || parts.any((e) => e.isEmpty)) {
      throw const FormatException('Could not generate a WireGuard key pair');
    }
    final privateKey = parts[0];
    final publicKey = parts[1];

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(Uri.parse(_endpoint)).timeout(timeout);
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, 'okhttp/3.12.1')
        ..set('CF-Client-Version', _clientVersion);
      request.write(
        jsonEncode({
          'key': publicKey,
          'install_id': '',
          'fcm_token': '',
          'warp_enabled': true,
          'tos': DateTime.now().toUtc().toIso8601String(),
          'type': 'Android',
          'model': 'PC',
          'locale': 'en_US',
        }),
      );

      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Cloudflare returned HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('Unexpected response');
      final config = decoded['config'];
      if (config is! Map) throw const FormatException('Response has no config');

      final peers = config['peers'];
      if (peers is! List || peers.isEmpty) {
        throw const FormatException('Response has no peer');
      }
      final peer = (peers.first as Map).cast<String, Object?>();
      final addresses = ((config['interface'] as Map)['addresses'] as Map).cast<String, Object?>();

      return WarpAccount(
        accountId: decoded['id'] as String? ?? '',
        token: decoded['token'] as String? ?? '',
        licensed: ((decoded['account'] as Map?)?['warp_plus'] as bool?) ?? false,
        privateKey: privateKey,
        peerPublicKey: peer['public_key'] as String? ?? '',
        endpointHost: _hostOf(((peer['endpoint'] as Map)['v4'] as String?) ?? ''),
        endpointPort: _wireGuardPort,
        addressV4: addresses['v4'] as String? ?? '',
        addressV6: addresses['v6'] as String? ?? '',
        reserved: _reservedFrom(config['client_id'] as String? ?? ''),
        registeredAt: DateTime.now(),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Attaches a WARP+ licence to an existing account.
  ///
  /// Returns the account marked licensed. Throws with Cloudflare's own wording when
  /// the key is refused, which is the only useful thing to show — a key can be
  /// mistyped, already bound to another device, or simply spent.
  Future<WarpAccount> applyLicense(WarpAccount account, String license) async {
    if (account.accountId.isEmpty || account.token.isEmpty) {
      // Registered before the app kept these. Re-registering is the only way back.
      throw const FormatException(
        'This WARP account was created by an older version. Turn WARP off and on again first.',
      );
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client
          .putUrl(Uri.parse('$_endpoint/${account.accountId}/account'))
          .timeout(timeout);
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, 'okhttp/3.12.1')
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${account.token}')
        ..set('CF-Client-Version', _clientVersion);
      request.write(jsonEncode({'license': license.trim()}));

      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(_errorFrom(body, response.statusCode));
      }
      final decoded = jsonDecode(body);
      final accepted = decoded is Map && (decoded['warp_plus'] as bool? ?? false);
      if (!accepted) throw const HttpException('Cloudflare did not accept that licence key');
      return account.copyWith(licensed: true);
    } finally {
      client.close(force: true);
    }
  }

  /// Cloudflare reports failures as a list of coded errors; the message is the part
  /// worth repeating.
  static String _errorFrom(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      final errors = decoded is Map ? decoded['errors'] : null;
      if (errors is List && errors.isNotEmpty) {
        final message = (errors.first as Map)['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // Fall through to the status code.
    }
    return 'Cloudflare returned HTTP $statusCode';
  }

  /// The response gives "host:port"; the port there is 0 and unusable.
  static String _hostOf(String value) {
    final colon = value.lastIndexOf(':');
    return colon < 0 ? value : value.substring(0, colon);
  }

  /// WARP's reserved bytes are simply the base64-decoded client id.
  static List<int> _reservedFrom(String clientId) {
    if (clientId.isEmpty) return const [];
    try {
      return base64.decode(clientId).take(3).toList();
    } catch (_) {
      return const [];
    }
  }
}
