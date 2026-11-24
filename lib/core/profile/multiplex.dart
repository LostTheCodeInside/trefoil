/// Many logical streams carried over one physical connection.
///
/// The win is on the handshake, not on throughput. Every fresh connection to a
/// proxy costs a round trip — three once TLS is on top — and a page pulling sixty
/// assets pays that sixty times. Muxed, it pays once and the rest ride along. On a
/// high-latency link that is the difference between a page appearing and a page
/// loading.
///
/// Off by default because the server has to agree. sing-box and Xray servers speak
/// it; a plain Shadowsocks server or a third-party implementation may not, and a
/// mux handshake nobody answers shows up as a connection that hangs rather than one
/// that says why. That failure is indistinguishable from a blocked server, so it is
/// not something to turn on for someone.
class MultiplexSettings {
  const MultiplexSettings({
    this.enabled = false,
    this.protocol = h2mux,
    this.maxStreams = 8,
    this.padding = false,
  });

  /// smux is the original and the most widely implemented; yamux is HashiCorp's,
  /// also common; h2mux rides HTTP/2 framing and is what sing-box recommends now.
  static const smux = 'smux';
  static const yamux = 'yamux';
  static const h2mux = 'h2mux';

  /// Ordered by what to reach for first.
  static const protocols = [h2mux, smux, yamux];

  /// Bounded on both ends. One stream per connection is mux doing nothing at a
  /// cost, and an unbounded ceiling turns one stalled connection into every request
  /// stalling behind it — head-of-line blocking is the standing risk of muxing.
  static const minStreams = 1;
  static const maxAllowedStreams = 128;

  final bool enabled;

  /// One of [protocols]. Must match what the server speaks.
  final String protocol;

  /// Streams to carry on one connection before opening another.
  ///
  /// sing-box treats `max_streams` as mutually exclusive with `max_connections`
  /// and `min_streams`, so this is deliberately the only knob: setting it is
  /// complete on its own, and offering all three invites configs the core rejects.
  final int maxStreams;

  /// Pads frames to blur the traffic's shape. Costs bandwidth; the server must
  /// have padding on too, or the connection fails outright.
  final bool padding;

  /// Outbound types with a `multiplex` field in sing-box 1.13.
  ///
  /// Checked against the option structs rather than assumed: hysteria2, tuic and
  /// anytls carry their own stream multiplexing over QUIC and have no such field,
  /// so adding one produces a config the core refuses to parse.
  static const supportedTypes = {'vmess', 'vless', 'trojan', 'shadowsocks'};

  static bool isValidProtocol(String value) => protocols.contains(value);

  static bool isValidStreamCount(int value) => value >= minStreams && value <= maxAllowedStreams;

  /// Whether this outbound should carry a `multiplex` block.
  ///
  /// VLESS with a `flow` is excluded even though the field parses: XTLS Vision
  /// splices the raw connection itself, and wrapping that in a mux stream defeats
  /// what Vision is for while still appearing to connect.
  static bool appliesTo(Map<String, Object?> outbound) {
    final type = outbound['type'];
    if (type is! String || !supportedTypes.contains(type)) return false;
    final flow = outbound['flow'];
    if (flow is String && flow.isNotEmpty) return false;
    return true;
  }

  MultiplexSettings copyWith({bool? enabled, String? protocol, int? maxStreams, bool? padding}) =>
      MultiplexSettings(
        enabled: enabled ?? this.enabled,
        protocol: protocol ?? this.protocol,
        maxStreams: maxStreams ?? this.maxStreams,
        padding: padding ?? this.padding,
      );

  /// The sing-box `multiplex` block.
  Map<String, Object?> toOption() => {
    'enabled': true,
    'protocol': protocol,
    'max_streams': maxStreams,
    if (padding) 'padding': true,
  };

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'protocol': protocol,
    'maxStreams': maxStreams,
    'padding': padding,
  };

  /// Every field is validated on the way in rather than trusted. A profile edited
  /// by hand, or restored from a backup written by a later version, must not be
  /// able to produce a config the core rejects — that would leave the tunnel unable
  /// to start with no way back through the UI.
  factory MultiplexSettings.fromJson(Map<String, Object?> map) {
    final protocol = map['protocol'] as String? ?? h2mux;
    final streams = (map['maxStreams'] as num?)?.toInt() ?? 8;
    return MultiplexSettings(
      enabled: map['enabled'] as bool? ?? false,
      protocol: isValidProtocol(protocol) ? protocol : h2mux,
      maxStreams: streams.clamp(minStreams, maxAllowedStreams),
      padding: map['padding'] as bool? ?? false,
    );
  }
}
