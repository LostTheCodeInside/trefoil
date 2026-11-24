import 'dart:async';
import 'dart:io';

/// How long it takes to open a TCP connection to a server's address.
///
/// The only honest measurement available while the tunnel is down. It is not a proxy
/// round trip — nothing is negotiated, no traffic is carried, and a server that
/// answers here can still refuse the handshake that follows — but it does answer the
/// question people actually ask of a list of servers before connecting to any of
/// them: which of these is near, and which is not there at all.
///
/// It says nothing about a server whose protocol is carried over UDP. There is no
/// equivalent probe for those: a WireGuard endpoint will not answer a packet it
/// cannot authenticate, and a TCP connection to its port has nothing listening for
/// it. Those are measurable only through the running core, which is where
/// [Outbound.reachableOverTcp] comes in.
class Reachability {
  const Reachability({
    this.timeout = const Duration(seconds: 5),
    this.samples = 2,
    this.connect = Socket.connect,
  });

  final Duration timeout;

  /// Connections opened per server. The lowest wins, for the same reason a ping does
  /// it: a single sample carries whatever queueing was in the way.
  final int samples;

  /// Injected so a test can point this at a socket it controls.
  final Future<Socket> Function(String host, int port, {Duration? timeout}) connect;

  /// Null when nothing answered before [timeout].
  Future<Duration?> measure(String host, int port) async {
    if (host.isEmpty || port <= 0) return null;
    Duration? best;
    for (var i = 0; i < samples; i++) {
      final began = DateTime.now();
      try {
        final socket = await connect(host, port, timeout: timeout);
        final took = DateTime.now().difference(began);
        socket.destroy();
        if (best == null || took < best) best = took;
      } catch (_) {
        // Refused, unroutable, or timed out. Another sample may still land.
      }
    }
    return best;
  }

  /// Measures many at once, a few at a time.
  ///
  /// Bounded because a long subscription is hundreds of servers, and opening hundreds
  /// of sockets at once is the kind of thing a phone's network stack, or somebody's
  /// router, declines to be part of.
  Future<Map<String, Duration>> measureAll(
    Map<String, ({String host, int port})> servers, {
    int concurrency = 8,
  }) async {
    final results = <String, Duration>{};
    final pending = servers.entries.toList();
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (next >= pending.length) return;
        final entry = pending[next++];
        final latency = await measure(entry.value.host, entry.value.port);
        if (latency != null) results[entry.key] = latency;
      }
    }

    await Future.wait([for (var i = 0; i < concurrency && i < pending.length; i++) worker()]);
    return results;
  }
}
