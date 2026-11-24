import 'dart:async';
import 'dart:io';

/// The address the outside world sees, once the tunnel is carrying traffic.
class ExitIp {
  const ExitIp({required this.address, required this.country});

  final String address;

  /// Two-letter country code, or empty when the service did not report one.
  final String country;

  String get label => country.isEmpty ? address : '$address · $country';
}

/// Asks what the exit address is, through whatever route the app currently has.
///
/// This is the one check that tells the user the tunnel is doing its job: connected
/// with an unchanged exit address means traffic is not going where they think. It is
/// still a request to a third party that the user did not make, which is why nothing
/// calls this unless the setting is on.
class ExitIpProbe {
  const ExitIpProbe({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;

  /// Cloudflare's trace endpoint: a few hundred bytes of `key=value` lines, no API
  /// key, and it reports the country alongside the address.
  static const endpoint = 'https://www.cloudflare.com/cdn-cgi/trace';

  /// A ceiling on a response that should be well under a kilobyte.
  static const maxBytes = 64 * 1024;

  /// Returns null when the lookup fails, which is an ordinary outcome — offline, or
  /// a tunnel that is up but not yet passing traffic.
  Future<ExitIp?> lookup() async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(endpoint)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) return null;

      var received = 0;
      final body = await response
          .map((chunk) {
            received += chunk.length;
            if (received > maxBytes) throw const HttpException('response too large');
            return chunk;
          })
          .transform(const SystemEncoding().decoder)
          .join()
          .timeout(timeout);
      return parse(body);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Exposed for tests. Returns null when the body carries no address.
  static ExitIp? parse(String body) {
    final fields = <String, String>{};
    for (final line in body.split('\n')) {
      final index = line.indexOf('=');
      if (index <= 0) continue;
      fields[line.substring(0, index).trim()] = line.substring(index + 1).trim();
    }
    final address = fields['ip'] ?? '';
    if (address.isEmpty) return null;
    // "XX" is what Cloudflare reports when it cannot place the address; showing it
    // would read as a country.
    final country = fields['loc'] ?? '';
    return ExitIp(address: address, country: country == 'XX' ? '' : country);
  }
}
