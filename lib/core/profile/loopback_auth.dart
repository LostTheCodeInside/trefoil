import 'dart:math';

/// How sing-box reaches the other two cores: a SOCKS5 server on loopback, with a
/// port and a pair of credentials drawn fresh for every connect.
///
/// Loopback is reachable by every app on the device, including the ones the user
/// excluded from the VPN. Left open, any of them could send traffic through the
/// tunnel and, by asking where it comes out, learn the server's address — exactly
/// what VPN detection looks for, and exactly what gets a server blocked. The
/// credentials close that. The random port is the smaller half: it keeps the
/// hand-off off the few well-known ports a detector probes first.
///
/// They live only in the generated configs, which sit in app-private storage beside
/// the server credentials they protect, and are never shown or persisted elsewhere.
class LoopbackAuth {
  const LoopbackAuth({
    required this.xrayPort,
    required this.amneziaPort,
    required this.username,
    required this.password,
  });

  /// A fresh set. [random] is for tests; production always uses a CSPRNG.
  factory LoopbackAuth.random([Random? random]) {
    final rng = random ?? Random.secure();
    final xrayPort = _port(rng);
    var amneziaPort = _port(rng);
    // Both cores can run in one session, and two listeners on one port is a start
    // failure with no useful message.
    while (amneziaPort == xrayPort) {
      amneziaPort = _port(rng);
    }
    return LoopbackAuth(
      xrayPort: xrayPort,
      amneziaPort: amneziaPort,
      username: _token(rng, 8),
      password: _token(rng, 24),
    );
  }

  final int xrayPort;
  final int amneziaPort;
  final String username;
  final String password;

  /// Drawn below Linux's ephemeral range (32768–60999), so an outgoing connection is
  /// never handed the port a core is about to listen on.
  static const portFloor = 20000;
  static const portCeiling = 32767;

  static int _port(Random rng) => portFloor + rng.nextInt(portCeiling - portFloor + 1);

  static String _token(Random rng, int bytes) =>
      [for (var i = 0; i < bytes; i++) rng.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}
