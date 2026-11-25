import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Measures the path the tunnel is actually taking.
///
/// Deliberately not a measurement of one outbound in isolation — the core cannot do
/// that anyway, its only test takes a whole group — but of what this device gets
/// right now, through whichever server is carrying traffic. That is the question
/// someone is asking when they have just switched servers and want to know whether
/// it was worth it.
///
/// Which means it is only true while the app's own traffic goes through the tunnel.
/// It does by default; a per-app rule that leaves this app out makes every figure
/// here a measurement of the bare connection instead, so the caller is expected to
/// say so rather than let the numbers speak for a tunnel they never touched.
class SpeedTest {
  const SpeedTest({
    this.openClient = _defaultClient,
    this.latencyUrl = defaultLatencyUrl,
    this.downloadUrl = defaultDownloadUrl,
    this.uploadUrl = defaultUploadUrl,
    this.budget = const Duration(seconds: 10),
    this.patience = const Duration(seconds: 10),
    this.samples = 3,
  });

  /// Injected so a test can serve this from a local socket and measure something
  /// real, rather than asserting that a mock was called.
  final HttpClient Function() openClient;

  final String latencyUrl;
  final String downloadUrl;
  final String uploadUrl;

  /// How long each half of the throughput test may run.
  ///
  /// A cap rather than a target: a fast link finishes the payload early and is
  /// measured over the time it actually took.
  final Duration budget;

  /// How long to wait for an answer to start.
  ///
  /// Connecting has its own limit and was the only thing that did, so a server that
  /// accepted the connection and then said nothing left the test running for good —
  /// which through a tunnel that carries nothing is the usual case, not the odd one.
  final Duration patience;

  /// How many round trips the latency figure is taken from.
  final int samples;

  /// An empty 204, the same one the core's own latency test fetches.
  static const defaultLatencyUrl = 'https://www.gstatic.com/generate_204';

  /// Cloudflare's speed endpoints: no key, no account, and they exist for this.
  static const defaultDownloadUrl = 'https://speed.cloudflare.com/__down?bytes=$_downloadBytes';
  static const defaultUploadUrl = 'https://speed.cloudflare.com/__up';

  static const _downloadBytes = 50 * 1024 * 1024;

  /// What [upload] sends, one after another over one connection. Growing, so that a slow
  /// link still gets an answer within the budget and a fast one is measured over enough
  /// to mean something. The last one answered is the figure.
  static const _uploadBlocks = [16 * 1024, 128 * 1024, 1024 * 1024, 8 * 1024 * 1024];

  static HttpClient _defaultClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    // The point is to measure the tunnel, and a system proxy would measure something
    // else without saying so.
    ..findProxy = (_) => 'DIRECT';

  /// Round trip to a server that answers with nothing.
  ///
  /// The lowest of [samples], not the mean: a single sample carries whatever
  /// queueing happened to be in the way, and the floor is the honest answer to "how
  /// far away is this".
  Future<Duration?> latency() async {
    final client = openClient();
    try {
      Duration? best;
      for (var i = 0; i < samples; i++) {
        final began = DateTime.now();
        try {
          final request = await client.getUrl(Uri.parse(latencyUrl)).timeout(patience);
          final response = await request.close().timeout(patience);
          await response.drain<void>().timeout(patience);
        } on TimeoutException {
          // Silence, and the next sample would be the same silence for as long again.
          break;
        } catch (_) {
          continue;
        }
        final took = DateTime.now().difference(began);
        if (best == null || took < best) best = took;
      }
      return best;
    } finally {
      client.close(force: true);
    }
  }

  /// Bits per second, or null when nothing arrived.
  Future<double?> download() async {
    final client = openClient();
    try {
      final request = await client.getUrl(Uri.parse(downloadUrl)).timeout(patience);
      final response = await request.close().timeout(patience);
      final began = DateTime.now();
      var received = 0;
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      // Timed from the first byte, and stopped by whichever comes first: the payload
      // ending or the budget running out.
      final deadline = Timer(budget, () {
        if (!done.isCompleted) done.complete();
      });
      subscription = response.listen(
        (chunk) {
          received += chunk.length;
          if (DateTime.now().difference(began) >= budget && !done.isCompleted) {
            done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;
      deadline.cancel();
      final elapsed = DateTime.now().difference(began);
      // Not awaited: cancelling a response the server is still writing into waits for
      // a drain that may never come. The client is force-closed below, which is what
      // actually ends it.
      unawaited(subscription.cancel());
      return _rate(received, elapsed);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Bits per second, or null when nothing was delivered.
  ///
  /// Timed until the server answers, which it does once it has the whole block. Handing
  /// the bytes to a socket says nothing: the buffers on the way, the tunnel's own among
  /// them, take megabytes before the link has carried any of it.
  Future<double?> upload() async {
    final client = openClient();
    double? rate;
    try {
      // Empty, so this is what a request costs on top of what it carries: the way there
      // and back, which is latency and has its own figure.
      final overhead = await _post(client, 0).timeout(patience);
      final clock = Stopwatch()..start();
      for (final bytes in _uploadBlocks) {
        final left = budget - clock.elapsed;
        if (left <= Duration.zero) break;
        final took = await _post(client, bytes).timeout(left);
        // Never less than half: the first request may have had a slower way than this.
        final carrying = took - overhead;
        rate = _rate(bytes, carrying > took ~/ 2 ? carrying : took ~/ 2);
      }
    } catch (_) {
      // Out of time, refused or cut off. What was answered until then still stands.
    } finally {
      client.close(force: true);
    }
    return rate;
  }

  /// Posts [bytes], and how long it took the server to have them and say so. Connecting
  /// is not part of it.
  Future<Duration> _post(HttpClient client, int bytes) async {
    final request = await client.postUrl(Uri.parse(uploadUrl));
    request.headers.contentType = ContentType.binary;
    request.contentLength = bytes;
    final clock = Stopwatch()..start();
    if (bytes > 0) await request.addStream(_noise(bytes));
    final response = await request.close();
    clock.stop();
    await response.drain<void>();
    // A refusal can come without anything having been delivered.
    if (response.statusCode ~/ 100 != 2) throw HttpException('${response.statusCode}');
    return clock.elapsed;
  }

  /// [bytes] of payload, made as it goes rather than held in memory.
  ///
  /// Not zeroes: a link or a middlebox that compresses would otherwise report a
  /// throughput nothing can reproduce with real data.
  static Stream<List<int>> _noise(int bytes) async* {
    final random = Random(1);
    final block = Uint8List(64 * 1024);
    for (var i = 0; i < block.length; i++) {
      block[i] = random.nextInt(256);
    }
    for (var left = bytes; left > 0; left -= block.length) {
      yield left < block.length ? Uint8List.sublistView(block, 0, left) : block;
    }
  }

  /// Bits per second, or null when there is nothing to divide.
  static double? _rate(int bytes, Duration elapsed) {
    if (bytes <= 0 || elapsed.inMicroseconds <= 0) return null;
    return bytes * 8 / (elapsed.inMicroseconds / 1000000);
  }
}

/// Formats bits per second the way a link is usually quoted.
String formatBitrate(double bitsPerSecond) {
  const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  var value = bitsPerSecond;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}
