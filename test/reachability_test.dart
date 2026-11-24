import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/wireguard_config.dart';
import 'package:trefoil/core/reachability.dart';

/// Against real sockets. What is under test is whether a connection opens and how
/// long it took, and a fake would only be able to answer the first half.
void main() {
  late ServerSocket listening;

  setUp(() async {
    listening = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    // Accepted and dropped: the probe only cares that the handshake completed.
    listening.listen((socket) => socket.destroy());
  });

  tearDown(() async => listening.close());

  group('measuring one server', () {
    test('a port that accepts is measured', () async {
      final latency = await const Reachability().measure('127.0.0.1', listening.port);
      expect(latency, isNotNull);
      expect(latency!.inSeconds, lessThan(5));
    });

    test('a port that refuses is null, not zero', () async {
      final port = listening.port;
      await listening.close();
      final latency = await const Reachability(
        samples: 1,
        timeout: Duration(seconds: 2),
      ).measure('127.0.0.1', port);
      expect(latency, isNull);
    });

    test('an address that is not one at all is null rather than an error', () async {
      expect(await const Reachability(samples: 1).measure('', 443), isNull);
      expect(await const Reachability(samples: 1).measure('127.0.0.1', 0), isNull);
    });

    // A server that answers once and hangs the second time is still reachable, and
    // the figure that describes it is the one that came back.
    test('one failed sample among good ones does not lose the reading', () async {
      var attempt = 0;
      final flaky = Reachability(
        samples: 3,
        connect: (host, port, {timeout}) {
          attempt++;
          if (attempt == 1) return Future.error(const SocketException('refused'));
          return Socket.connect(host, port, timeout: timeout);
        },
      );
      expect(await flaky.measure('127.0.0.1', listening.port), isNotNull);
      expect(attempt, 3);
    });
  });

  group('measuring a list', () {
    test('keeps the ones that answered and leaves out the rest', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = closed.port;
      await closed.close();

      final results = await const Reachability(samples: 1, timeout: Duration(seconds: 2))
          .measureAll({
            'alive': (host: '127.0.0.1', port: listening.port),
            'dead': (host: '127.0.0.1', port: deadPort),
          });

      expect(results.keys, ['alive']);
    });

    test('an empty list is not an error', () async {
      expect(await const Reachability().measureAll(const {}), isEmpty);
    });

    // Hundreds of servers is an ordinary subscription, and opening hundreds of
    // sockets at once is what a phone's network stack declines to be part of.
    test('opens only so many at a time', () async {
      var open = 0;
      var peak = 0;
      final counted = Reachability(
        samples: 1,
        connect: (host, port, {timeout}) async {
          open++;
          if (open > peak) peak = open;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          open--;
          return Socket.connect(host, port, timeout: timeout);
        },
      );
      await counted.measureAll({
        for (var i = 0; i < 40; i++) 'server$i': (host: '127.0.0.1', port: listening.port),
      }, concurrency: 4);
      expect(peak, lessThanOrEqualTo(4));
    });
  });

  // A probe on a UDP port measures the absence of a TCP service, not the distance to
  // a server, so those are skipped rather than reported as unreachable.
  group('which servers a TCP probe can speak for', () {
    test('the ones carried over TCP', () {
      for (final link in [
        'trojan://pw@a.example:443#T',
        'vless://11111111-2222-3333-4444-555555555555@a.example:443#V',
        'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@a.example:8388#S',
      ]) {
        expect(ShareLink.parse(link)!.reachableOverTcp, isTrue, reason: link);
      }
    });

    test('and not the ones carried over UDP', () {
      for (final link in [
        'hysteria2://pw@a.example:443#H2',
        'tuic://11111111-2222-3333-4444-555555555555:pw@a.example:443#T',
      ]) {
        expect(ShareLink.parse(link)!.reachableOverTcp, isFalse, reason: link);
      }
      final wg = WireGuardConfig.parse(
        'wireguard://aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gMTI%3D@1.2.3.4:51820'
        '?publickey=bmV4dCBrZXkgbmV4dCBrZXkgbmV4dCBrZXkgbmV4dDI%3D&address=10.7.0.2/32#WG',
      )!;
      expect(wg.reachableOverTcp, isFalse);
    });
  });
}
