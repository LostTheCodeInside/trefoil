import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/speed_test.dart';

/// Measured against a real socket rather than a mock. The thing under test is a
/// measurement; asserting that a fake was called would prove nothing about it.
void main() {
  late HttpServer server;
  late String origin;
  // A handler that writes until told to stop would otherwise keep writing into the
  // next test, and the isolate with it. Closing the socket is not enough on its own:
  // a response that nobody is reading absorbs writes for a long time first.
  late bool stopped;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    stopped = false;
  });

  tearDown(() async {
    stopped = true;
    await server.close(force: true);
  });

  /// Serves [handle], swallowing the disconnects a speed test causes by design.
  void serve(Future<void> Function(HttpRequest request) handle) {
    unawaited(
      server
          .forEach((request) {
            unawaited(handle(request).catchError((Object _) {}));
          })
          .catchError((Object _) {}),
    );
  }

  SpeedTest testing({Duration budget = const Duration(seconds: 5), int samples = 3}) => SpeedTest(
    latencyUrl: '$origin/204',
    downloadUrl: '$origin/down',
    uploadUrl: '$origin/up',
    budget: budget,
    samples: samples,
  );

  group('latency', () {
    test('comes back as a duration when the server answers', () async {
      var served = 0;
      serve((request) async {
        served++;
        request.response.statusCode = 204;
        await request.response.close();
      });

      final latency = await testing().latency();
      expect(latency, isNotNull);
      expect(latency!.inMilliseconds, lessThan(5000));
      expect(served, 3, reason: 'the lowest of three, so three have to be taken');
    });

    test('is null rather than zero when nothing answers', () async {
      await server.close(force: true);
      expect(await testing(samples: 1).latency(), isNull);
    });

    // One slow sample among fast ones is queueing, not distance.
    test('reports the lowest sample, not the last', () async {
      var first = true;
      serve((request) async {
        if (first) {
          first = false;
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        request.response.statusCode = 204;
        await request.response.close();
      });

      final latency = await testing(samples: 3).latency();
      expect(latency!.inMilliseconds, lessThan(300));
    });
  });

  // A server that accepts the connection and then says nothing, which is what a tunnel
  // carrying nothing looks like from here. Connecting was the only step with a limit,
  // so the test ran for good.
  group('a server that never answers', () {
    SpeedTest impatient() => SpeedTest(
      latencyUrl: '$origin/204',
      downloadUrl: '$origin/down',
      uploadUrl: '$origin/up',
      budget: const Duration(milliseconds: 300),
      patience: const Duration(milliseconds: 300),
      samples: 3,
    );

    setUp(() => serve((request) => Completer<void>().future));

    test('ends the latency test, and after one wait rather than three', () async {
      final clock = Stopwatch()..start();
      expect(await impatient().latency(), isNull);
      expect(clock.elapsedMilliseconds, lessThan(800));
    });

    test('ends the download', () async {
      expect(await impatient().download().timeout(const Duration(seconds: 5)), isNull);
    });

    test('ends the upload', () async {
      expect(await impatient().upload().timeout(const Duration(seconds: 5)), isNull);
    });
  });

  group('download', () {
    test('measures what actually arrived', () async {
      final payload = Uint8List(2 * 1024 * 1024);
      serve((request) async {
        request.response.add(payload);
        await request.response.close();
      });

      final rate = await testing().download();
      expect(rate, isNotNull);
      expect(rate, greaterThan(0));
    });

    // A link fast enough to outrun the payload is measured over the time it took,
    // not over the budget it did not use.
    test('a stream that never ends is cut off at the budget', () async {
      serve((request) async {
        final block = Uint8List(64 * 1024);
        while (!stopped) {
          request.response.add(block);
          await request.response.flush();
        }
      });

      final began = DateTime.now();
      final rate = await testing(budget: const Duration(milliseconds: 700)).download();
      final took = DateTime.now().difference(began);
      expect(rate, isNotNull);
      expect(took.inSeconds, lessThan(5), reason: 'the budget has to actually stop it');
    });

    test('is null when the server refuses', () async {
      serve((request) async {
        request.response.statusCode = 500;
        await request.response.close();
      });
      // Nothing in the body, so there is nothing to divide by time.
      expect(await testing().download(), isNull);
    });
  });

  group('upload', () {
    /// Takes the body at [bytesPerSecond], as a link that slow would deliver it.
    Future<int> read(HttpRequest request, {int? bytesPerSecond}) async {
      final clock = Stopwatch()..start();
      var received = 0;
      await for (final chunk in request) {
        received += chunk.length;
        if (bytesPerSecond == null) continue;
        final due = Duration(microseconds: received * 1000000 ~/ bytesPerSecond);
        if (due > clock.elapsed) await Future<void>.delayed(due - clock.elapsed);
      }
      return received;
    }

    test('sends all of it and measures it', () async {
      final received = <int>[];
      serve((request) async {
        received.add(await read(request));
        await request.response.close();
      });

      final rate = await testing().upload();
      expect(rate, isNotNull);
      expect(rate, greaterThan(0));
      expect(received.first, 0, reason: 'what an empty request costs is not throughput');
      expect(received.last, 8 * 1024 * 1024);
    });

    // The buffers of a loopback connection alone take all of it at once, and the figure
    // was the speed of that: hundreds of megabits for a link that carries eight.
    test('is the rate of the link, not of the buffers in front of it', () async {
      serve((request) async {
        await read(request, bytesPerSecond: 1024 * 1024);
        await request.response.close();
      });

      final rate = await testing(budget: const Duration(seconds: 2)).upload();
      expect(rate, isNotNull);
      expect(rate, inInclusiveRange(1e6, 17e6), reason: '1 MiB a second is 8.4 Mbps');
    });

    test('keeps the figure it has when the rest goes unanswered', () async {
      var requests = 0;
      serve((request) async {
        if (++requests > 3) return Completer<void>().future;
        await read(request);
        await request.response.close();
      });

      final clock = Stopwatch()..start();
      final rate = await testing(budget: const Duration(milliseconds: 700)).upload();
      expect(rate, isNotNull);
      expect(clock.elapsed.inSeconds, lessThan(5), reason: 'the budget has to actually stop it');
    });

    test('is null when the connection is cut on the first block', () async {
      var requests = 0;
      serve((request) async {
        if (++requests > 1) {
          (await request.response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        await read(request);
        await request.response.close();
      });

      expect(await testing().upload(), isNull);
    });

    test('is null when the server refuses', () async {
      serve((request) async {
        await read(request);
        request.response.statusCode = 429;
        await request.response.close();
      });

      expect(await testing().upload(), isNull);
    });

    test('is null when there is nowhere to send it', () async {
      await server.close(force: true);
      expect(await testing().upload(), isNull);
    });
  });

  group('formatting', () {
    test('reads the way a link is usually quoted', () {
      expect(formatBitrate(500), '500 bps');
      expect(formatBitrate(1500), '1.5 Kbps');
      expect(formatBitrate(12300000), '12.3 Mbps');
      expect(formatBitrate(250000000), '250 Mbps');
      expect(formatBitrate(2400000000), '2.4 Gbps');
    });
  });
}
