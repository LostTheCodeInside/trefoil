import 'package:flutter_test/flutter_test.dart';
import 'package:trefoil/core/profile/amnezia_obfuscation.dart';

/// The arithmetic behind the warning on a server's row.
///
/// The numbers here are not invented: this is the shape of a real server, and the
/// 2.14% it predicts was measured on a phone at 2.30% — 157 packets dropped out of
/// 6823 in one 8 MB download, with the tunnel held to 0.4 MB/s while the same fetch
/// outside it carried 9 MB/s.
void main() {
  String conf({
    String trailers = 'RandomTrailers = on',
    String prefixes = 'S1 = 123\nS2 = 82\nS3 = 38\nS4 = 20',
    String headers =
        'H1 = 410000001-416021364\n'
        'H2 = 900000001-981496461\n'
        'H3 = 1500000001-1504503530\n'
        'H4 = 1700000001-2078121096',
  }) =>
      '[Interface]\nPrivateKey = x\nAddress = 10.8.1.3/32\n'
      'Jc = 3\n$prefixes\n$headers\n$trailers\n\n'
      '[Peer]\nPublicKey = y\nEndpoint = 1.2.3.4:51820\n';

  test('the shape that cost twenty times the throughput is named', () {
    // H1 covers 0.140%, H2 1.898%, H3 0.105%.
    expect(amneziaObfuscationLoss(conf()), closeTo(0.0214, 0.0002));
  });

  test('no trailers, no loss', () {
    expect(amneziaObfuscationLoss(conf(trailers: 'RandomTrailers = off')), 0);
    // Absent means off: the device only relaxes its size checks when told to.
    expect(amneziaObfuscationLoss(conf(trailers: '')), 0);
  });

  // Every test then reads the real type field, which was drawn from H4 and so cannot
  // fall in H1-H3. This is what the AmneziaWG documentation recommends.
  test('one junk prefix for every message type is safe at any range width', () {
    expect(amneziaObfuscationLoss(conf(prefixes: 'S1 = 20\nS2 = 20\nS3 = 20\nS4 = 20')), 0);
  });

  // The other documented shape: with header protection doing the hiding, H1-H4 are
  // left at the values that mean "no custom header", and one value in four billion
  // is not a risk.
  test('single-value headers are safe even with mismatched prefixes', () {
    final loss = amneziaObfuscationLoss(conf(headers: 'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4'));
    expect(loss, lessThan(0.000001));
  });

  test('only the branches whose prefix differs from the transport one count', () {
    // S2 now matches S4, so H2's 1.898% drops out and only H1 and H3 remain.
    expect(
      amneziaObfuscationLoss(conf(prefixes: 'S1 = 123\nS2 = 20\nS3 = 38\nS4 = 20')),
      closeTo(0.00245, 0.0002),
    );
  });

  test('a config with none of this in it is not accused of anything', () {
    expect(amneziaObfuscationLoss(''), 0);
    expect(amneziaObfuscationLoss('[Interface]\nPrivateKey = x\n[Peer]\nPublicKey = y\n'), 0);
  });

  test('a malformed range is read as one value rather than crashing', () {
    // One value in four billion, three times over — which is to say, nothing.
    expect(
      amneziaObfuscationLoss(conf(headers: 'H1 = nonsense-\nH2 = -\nH3 = 9-2')),
      lessThan(0.000001),
    );
  });
}
