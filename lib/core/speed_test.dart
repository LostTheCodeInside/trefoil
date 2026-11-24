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

  /// How many round trips the latency figure is taken from.
  final int samples;

  /// An empty 204, the same one the core's own latency test fetches.
  static const defaultLatencyUrl = 'https://www.gstatic.com/generate_204';

  /// Cloudflare's speed endpoints: no key, no account, and they exist for this.
  static const defaultDownloadUrl = 'https://speed.cloudflare.com/__down?bytes=$_downloadBytes';
  static const defaultUploadUrl = 'https://speed.cloudflare.com/__up';

  static const _downloadBytes = 50 * 1024 * 1024;
  static const _uploadBytes = 10 * 1024 * 1024;

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
          final request = await client.getUrl(Uri.parse(latencyUrl));
          final response = await request.close();
          await response.drain<void>();
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
      final request = await client.getUrl(Uri.parse(downloadUrl));
      final response = await request.close();
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

  /// Bits per second, or null when nothing could be sent.
  ///
  /// The payload is generated as it goes rather than held in memory: ten megabytes
  /// of buffer is ten megabytes this app did not need to allocate.
  Future<double?> upload() async {
    final client = openClient();
    try {
      final request = await client.postUrl(Uri.parse(uploadUrl));
      request.headers.contentType = ContentType.binary;
      // Chunked, rather than a declared length. The budget can stop this early, and a
      // body shorter than its own Content-Length is a broken request rather than a
      // short one.
      request.contentLength = -1;

      final began = DateTime.now();
      var sent = 0;
      const chunk = 64 * 1024;
      final block = Uint8List(chunk);
      // Not zeroes: a link or a middlebox that compresses would otherwise report a
      // throughput nothing can reproduce with real data.
      final random = Random(1);
      for (var i = 0; i < chunk; i++) {
        block[i] = random.nextInt(256);
      }

      while (sent < _uploadBytes) {
        if (DateTime.now().difference(began) >= budget) break;
        final size = min(chunk, _uploadBytes - sent);
        request.add(size == chunk ? block : Uint8List.sublistView(block, 0, size));
        await request.flush();
        sent += size;
      }
      final elapsed = DateTime.now().difference(began);
      // Finished properly rather than dropped. The measurement is already taken, and
      // aborting the socket here shows up at the other end as an error we caused —
      // bounded, because waiting on a reply is not part of what is being measured.
      try {
        final response = await request.close().timeout(const Duration(seconds: 5));
        await response.drain<void>();
      } catch (_) {
        // The body is sent either way; the reply is not the measurement.
      }
      return _rate(sent, elapsed);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
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
