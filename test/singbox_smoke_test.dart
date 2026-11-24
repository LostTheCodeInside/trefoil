@Tags(['smoke'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/clash_config.dart';
import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/multiplex.dart';
import 'package:trefoil/core/profile/outbound.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/warp.dart';
import 'package:trefoil/core/profile/wireguard_config.dart';

/// Runs the configs this app generates through the real sing-box binary.
///
/// Every other test here asserts on a Map in memory, which is a check that the code
/// produced what the code meant to produce. It is not a check that the core will
/// accept it. Two separate bugs have now shipped that passed every such test *and*
/// passed `sing-box check`, and then carried no traffic at all on the phone: the core
/// resolves dialers lazily, on the first packet, so a config can be structurally
/// perfect and still refuse to send a byte.
///
/// So this starts the core, points a connection at it, and reads what it says.
///
/// The servers are unreachable on purpose. Reachability is not what is being tested
/// and would make the test depend on the network; what is being tested is everything
/// the core decides *before* it gets to the wire. Failures that mean "the wire did
/// not answer" are expected and ignored; failures that mean "this config does not
/// make sense" are the point. [_configFailures] is that line.
///
/// The binary is not in the repository — it is 49 MB. Build one per machine:
///
///     cp -r ~/go/pkg/mod/github.com/sagernet/sing-box@v1.14.4 /tmp/sb && chmod -R u+w /tmp/sb
///     cd /tmp/sb && GOFLAGS=-mod=mod go build \
///       -tags "with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api" \
///       -o <repo>/tool/sing-box ./cmd/sing-box
///
/// The default build tags are in `release/DEFAULT_BUILD_TAGS_OTHERS`; the two
/// `linkname` ones there are dropped because they reference crypto/tls internals that
/// have since moved, and nothing under test needs them. Without a binary every case
/// here skips, so a machine that has not built one still gets a green suite.
void main() {
  final binary = _binary();
  if (binary == null) {
    test('the real core is not available, so nothing was actually run', () {
      markTestSkipped(
        'No sing-box binary. Build one into tool/sing-box or set TREFOIL_SINGBOX. '
        'See the header of test/singbox_smoke_test.dart.',
      );
    }, skip: 'no binary');
    return;
  }

  for (final entry in _cases().entries) {
    test(entry.key, () async {
      final report = await _run(binary, entry.value);
      expect(
        report.checkPassed,
        isTrue,
        reason: 'sing-box check rejected the config:\n${report.checkOutput}',
      );
      expect(
        report.stillRunning,
        isTrue,
        reason: 'the core exited instead of running:\n${report.log}',
      );
      expect(
        report.probeReached,
        isTrue,
        reason: 'nothing was driven through the core, so nothing was tested:\n${report.log}',
      );
      expect(
        report.failures,
        isEmpty,
        reason: 'the core refused to carry traffic:\n${report.failures.join('\n')}',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}

/// Lines that mean the config is wrong, as opposed to the network being absent.
///
/// Deliberately a small, specific list. Matching anything that merely looks like an
/// error would catch "connection refused" from the unreachable servers, and a test
/// that fails for the expected reason is a test nobody trusts.
const _configFailures = [
  // Both of this session's bugs. Reported once per second, forever, while the tunnel
  // sat there looking connected.
  'makes no sense',
  'detour not found',
  'outbound not found',
  'endpoint not found',
  // A hysteria v1 server built without its mandatory bandwidth figures.
  'missing upload speed',
  'missing download speed',
  // A protocol or field the bundled core does not have.
  'unknown outbound type',
  'unknown endpoint type',
  'unknown inbound type',
  'json: unknown field',
  'decode config',
  'invalid config',
  // A rule set the config names but nothing wrote to disk.
  'rule-set not found',
];

File? _binary() {
  final override = Platform.environment['TREFOIL_SINGBOX'];
  if (override != null && override.isNotEmpty) {
    final file = File(override);
    return file.existsSync() ? file : null;
  }
  final local = File('tool/sing-box');
  return local.existsSync() ? local : null;
}

class _Report {
  const _Report({
    required this.checkPassed,
    required this.checkOutput,
    required this.stillRunning,
    required this.probeReached,
    required this.log,
    required this.failures,
  });

  final bool checkPassed;
  final String checkOutput;
  final bool stillRunning;

  /// Whether the core actually saw the probe connection.
  final bool probeReached;

  final String log;
  final List<String> failures;
}

Future<_Report> _run(File binary, Map<String, Object?> config) async {
  final port = await _freePort();
  final dir = Directory.systemTemp.createTempSync('trefoil-smoke');
  final file = File('${dir.path}/config.json');
  file.writeAsStringSync(jsonEncode(_forHost(config, port)));

  try {
    // Run where the config is: the core writes its cache file into its working
    // directory, which would otherwise be the repository.
    final check = await Process.run(binary.absolute.path, [
      'check',
      '-c',
      file.path,
    ], workingDirectory: dir.path);
    if (check.exitCode != 0) {
      return _Report(
        checkPassed: false,
        checkOutput: '${check.stdout}${check.stderr}',
        stillRunning: false,
        probeReached: false,
        log: '',
        failures: const [],
      );
    }

    final process = await Process.start(binary.absolute.path, [
      'run',
      '-c',
      file.path,
    ], workingDirectory: dir.path);
    final output = StringBuffer();
    final done = [
      process.stdout.transform(utf8.decoder).forEach(output.write),
      process.stderr.transform(utf8.decoder).forEach(output.write),
    ];
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));

    // Probing before the inbound is listening reaches nothing, kills the core, and
    // reports a clean run -- a test that passes because it never ran.
    final listening = await _awaitListening(port);
    if (listening) {
      // One request through the inbound, which is what makes the core resolve its
      // dialers. Its outcome is irrelevant -- it cannot succeed -- but the attempt is
      // what turns a lazily broken config into a log line.
      await _probe(port);
      // Lazily-resolved failures are logged when the dial is attempted, not when the
      // request is made, and a retrying endpoint reports about once a second.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }

    process.kill();
    await Future.wait(done).timeout(const Duration(seconds: 5), onTimeout: () => const []);

    final log = output.toString();
    return _Report(
      checkPassed: true,
      checkOutput: '',
      stillRunning: !exited,
      // Proof the probe landed. Without it a silent run means "nothing was tested"
      // rather than "nothing was wrong", and the two look identical from here.
      probeReached: log.contains('probe-in'),
      log: log,
      failures: [
        for (final line in const LineSplitter().convert(log))
          if (_configFailures.any(line.toLowerCase().contains)) line,
      ],
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Makes a phone's config runnable on a desktop, changing as little as possible.
///
/// Only two things go: the tun inbound, which needs root and a device, and the Clash
/// API, whose fixed port would collide between concurrent cases. Everything the bugs
/// live in — outbounds, endpoints, route, dns — is left exactly as the app wrote it.
Map<String, Object?> _forHost(Map<String, Object?> config, int port) => {
  ...config,
  'log': {'level': 'debug', 'timestamp': false},
  'inbounds': [
    {'type': 'mixed', 'tag': 'probe-in', 'listen': '127.0.0.1', 'listen_port': port},
  ],
}..remove('experimental');

Future<void> _probe(int port) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 1500)
    ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
  try {
    final request = await client
        .getUrl(Uri.parse('http://cp.cloudflare.com/generate_204'))
        .timeout(const Duration(milliseconds: 1500));
    final response = await request.close().timeout(const Duration(milliseconds: 1500));
    await response.drain<void>();
  } catch (_) {
    // Expected: nothing here can reach a server. The log is the output, not this.
  } finally {
    client.close(force: true);
  }
}

/// Waits for the core to bind its inbound, which it does after everything else.
Future<bool> _awaitListening(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 200),
      );
      socket.destroy();
      return true;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  return false;
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

// ---- the configs ------------------------------------------------------------

const _wgConf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=
Address = 10.0.0.2/32, fd00::2/128
MTU = 1408

[Peer]
PublicKey = bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.1:51820
PersistentKeepalive = 25
''';

/// What a provider actually ships for ShadowTLS: one Shadowsocks proxy with a
/// plugin. sing-box has no such plugin, and an unknown plugin name is fatal for the
/// whole config rather than for the one server.
const _clashShadowTls = '''
proxies:
  - name: STLS
    type: ss
    server: 192.0.2.20
    port: 443
    cipher: aes-256-gcm
    password: pw
    plugin: shadow-tls
    plugin-opts:
      host: www.microsoft.com
      password: stlspw
      version: 3
      alpn:
        - h2
''';

/// A plugin nothing can run, beside a server that is perfectly fine.
const _clashBadPlugin = '''
proxies:
  - name: Fine
    type: ss
    server: 192.0.2.21
    port: 8388
    cipher: aes-256-gcm
    password: pw
  - name: Exotic
    type: ss
    server: 192.0.2.22
    port: 8388
    cipher: aes-256-gcm
    password: pw
    plugin: some-plugin-from-a-fork
''';

/// AmneziaWG, so the config carries the third core's loopback member too.
const _amneziaConf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=
Address = 10.8.1.2/32
Jc = 3
Jmin = 51
Jmax = 109
S1 = 123
S2 = 82
H1 = 410000001-416021364
H4 = 1700000001-2078121096

[Peer]
PublicKey = bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.12:51820
''';

final _warp = WarpAccount(
  privateKey: 'aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI=',
  peerPublicKey: 'bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI=',
  endpointHost: '192.0.2.2',
  endpointPort: 2408,
  addressV4: '172.16.0.2',
  addressV6: 'fd01::2',
  reserved: const [1, 2, 3],
  registeredAt: DateTime(2026),
);

Map<String, Map<String, Object?>> _cases() {
  final vless = ShareLink.parse(
    'vless://11111111-2222-3333-4444-555555555555@192.0.2.10:443'
    '?type=ws&security=tls&sni=example.com&path=%2Fws#VLESS',
  )!;
  final trojan = ShareLink.parse('trojan://pw@192.0.2.11:443#Trojan')!;
  final ss = ShareLink.parse('ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@192.0.2.12:8388#Shadowsocks')!;
  final wg = WireGuardConfig.parse(_wgConf, name: 'WG')!;

  // A server saved by a version of the app that wrote a detour to the bare direct
  // outbound. Nothing the parsers do reaches one of these; it is repaired on its way
  // into the config, and this is the case that proves the repair against the core.
  final legacyWg = Outbound.fromStorage({
    ...wg.toStorage(),
    'json': {...wg.json, 'detour': 'direct'},
  });

  return {
    'one server, the ordinary case': ConfigBuilder(routing: const RoutingSettings())
        .buildMap(vless, servers: [vless]),

    'several protocols, so the selector and the latency test are real': ConfigBuilder(
      routing: const RoutingSettings(),
    ).buildMap(vless, servers: [vless, trojan, ss, wg]),

    // The local proxies locked behind a login, and shared on the network: the
    // `users` field and a non-loopback listener have to be something the core takes.
    'local proxies that demand a login': ConfigBuilder(
      routing: const RoutingSettings(),
      mixedPort: 22080,
      directPort: 22081,
      shareInLocalNetwork: true,
    ).withProxyCredentials().buildMap(vless, servers: [vless]),

    'a WireGuard endpoint': ConfigBuilder(routing: const RoutingSettings())
        .buildMap(wg, servers: [wg]),

    'a WireGuard server saved before the detour fix': ConfigBuilder(
      routing: const RoutingSettings(),
    ).buildMap(legacyWg, servers: [legacyWg]),

    'WARP dialling out on its own': ConfigBuilder(
      routing: RoutingSettings(warp: _warp, warpThroughProxy: false),
    ).buildMap(vless, servers: [vless]),

    'WARP as the exit for everything': ConfigBuilder(
      routing: RoutingSettings(warp: _warp, warpThroughProxy: false, warpForAll: true),
    ).buildMap(vless, servers: [vless]),

    // Two outbounds from one proxy, wired by a detour this app assigns. Checking the
    // map would only prove it built what it meant to; the core has to accept it.
    'Shadowsocks over ShadowTLS, imported from Clash': () {
      final stls = ClashConfig.parse(_clashShadowTls).single;
      return ConfigBuilder(routing: const RoutingSettings()).buildMap(stls, servers: [stls]);
    }(),

    // The whole point of marking it unsupported: one entry nothing can run used to
    // stop the tunnel starting at all, taking every other server down with it.
    'a plugin from somebody else\'s core, beside a server that works': () {
      final proxies = ClashConfig.parse(_clashBadPlugin);
      return ConfigBuilder(routing: const RoutingSettings())
          .buildMap(proxies.first, servers: proxies);
    }(),

    // Both loopback members at once: one for Xray, one for AmneziaWG, beside a server
    // sing-box speaks itself. This is the config every server in a mixed list now
    // gets, and the core has to accept two proxies pointed at ports nothing is
    // listening on yet -- which it does, because they are dialled, not bound.
    'a server for each of the three cores': () {
      final wg = WireGuardConfig.parse(_wgConf, name: 'WG')!;
      final awg = WireGuardConfig.parse(_amneziaConf, name: 'AWG')!;
      final xray = ShareLink.parse(
        'vless://11111111-2222-3333-4444-555555555555@192.0.2.13:443'
        '?security=reality&pbk=k&fp=chrome&sni=x.example&pqv=abc&mldsa65Verify=abc#Xray',
      )!;
      return ConfigBuilder(routing: const RoutingSettings()).buildMap(wg, servers: [wg, awg, xray]);
    }(),

    'multiplex, custom rules and a relaxed certificate check': ConfigBuilder(
      routing: const RoutingSettings(
        rules: [
          RoutingRule(
            match: RuleMatch.domainSuffix,
            action: RuleAction.proxy,
            value: 'example.com',
          ),
          RoutingRule(
            match: RuleMatch.domainSuffix,
            action: RuleAction.block,
            value: 'ads.example',
          ),
          RoutingRule(match: RuleMatch.port, action: RuleAction.direct, value: '25'),
        ],
      ),
      multiplex: const MultiplexSettings(enabled: true),
      allowInsecure: true,
    ).buildMap(vless, servers: [vless, trojan]),
  };
}
