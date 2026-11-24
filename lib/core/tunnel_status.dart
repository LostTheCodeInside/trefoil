import 'package:flutter/foundation.dart' show listEquals;

/// Lifecycle of the native tunnel, mirrored from `TunnelStage` on the Android side.
enum TunnelStage {
  stopped,
  starting,
  started,
  stopping;

  static TunnelStage parse(Object? raw) => switch (raw) {
    'starting' => TunnelStage.starting,
    'started' => TunnelStage.started,
    'stopping' => TunnelStage.stopping,
    _ => TunnelStage.stopped,
  };

  bool get isBusy => this == starting || this == stopping;
  bool get isActive => this == started;
}

/// Whether the tunnel is doing its job, as opposed to merely being up.
///
/// A VPN client that reports "connected" is answering the wrong question. The tunnel
/// coming up says the core started and the interface exists; it says nothing about
/// whether a single packet reaches the other end. Those two states look identical on
/// screen and completely different to the person holding the phone.
enum TunnelHealth {
  /// Not connected, nothing measured yet, or routing that does not use the proxy.
  unknown,

  /// The server answered through the tunnel.
  healthy,

  /// The tunnel is up and the server is not answering through it.
  stalled,
}

/// A snapshot of the tunnel: lifecycle plus whatever telemetry the core last reported.
///
/// Status and telemetry are deliberately one object. They arrive from two different
/// native sources and merging them at the boundary means the UI can never render a
/// half-updated combination, such as live traffic counters next to "disconnected".
class TunnelStatus {
  const TunnelStatus({
    this.stage = TunnelStage.stopped,
    this.profileName = '',
    this.error,
    this.uplink = 0,
    this.downlink = 0,
    this.uplinkTotal = 0,
    this.downlinkTotal = 0,
    this.memory = 0,
    this.goroutines = 0,
    this.connectionsIn = 0,
    this.connectionsOut = 0,
    this.trafficAvailable = false,
    this.mode = '',
    this.startedAt = 0,
  });

  final TunnelStage stage;
  final String profileName;

  /// Why the last run ended. Survives the return to [TunnelStage.stopped] so the UI
  /// can explain a failure the user never saw happen.
  final String? error;

  final int uplink;
  final int downlink;
  final int uplinkTotal;
  final int downlinkTotal;
  final int memory;
  final int goroutines;
  final int connectionsIn;
  final int connectionsOut;

  /// False until the core has a clash-api traffic source attached; the counters are
  /// meaningless rather than zero when this is false.
  final bool trafficAvailable;

  /// Quick routing mode: Rule, Global or Direct. Empty while disconnected.
  final String mode;

  /// Epoch milliseconds the tunnel came up, or 0 when it is not running.
  ///
  /// Stamped by the service, not by the UI. The tunnel outlives the app, so a clock
  /// started when the screen was built would reset every time Android recreated the
  /// Activity and report an uptime far shorter than the truth.
  final int startedAt;

  /// [startedAt] as a time, or null when the tunnel is not up.
  DateTime? get startedAtTime =>
      startedAt <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(startedAt);

  static const disconnected = TunnelStatus();

  factory TunnelStatus.fromMap(Map<Object?, Object?> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return TunnelStatus(
      stage: TunnelStage.parse(map['stage']),
      profileName: map['profileName'] as String? ?? '',
      error: map['error'] as String?,
      uplink: intOf('uplink'),
      downlink: intOf('downlink'),
      uplinkTotal: intOf('uplinkTotal'),
      downlinkTotal: intOf('downlinkTotal'),
      memory: intOf('memory'),
      goroutines: intOf('goroutines'),
      connectionsIn: intOf('connectionsIn'),
      connectionsOut: intOf('connectionsOut'),
      trafficAvailable: map['trafficAvailable'] as bool? ?? false,
      mode: map['mode'] as String? ?? '',
      startedAt: intOf('startedAt'),
    );
  }

  @override
  String toString() => 'TunnelStatus(${stage.name}, profile: $profileName, error: $error)';
}

/// One line from the core's log ring buffer.
class CoreLogEntry {
  const CoreLogEntry({required this.level, required this.message});

  /// sing-box level: 0 panic … 5 debug, ascending in verbosity.
  final int level;
  final String message;

  bool get isError => level <= 2;

  factory CoreLogEntry.fromMap(Map<Object?, Object?> map) => CoreLogEntry(
    level: (map['level'] as num?)?.toInt() ?? 5,
    message: map['message'] as String? ?? '',
  );
}

/// An installed app, for building per-app proxy rules.
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    required this.isSystem,
    this.isBackground = false,
  });

  final String packageName;
  final String label;
  final bool isSystem;

  /// A system app with no launcher entry, such as Google Play Services: hidden from
  /// the per-app list unless asked for, but still choosable.
  final bool isBackground;

  factory InstalledApp.fromMap(Map<Object?, Object?> map) => InstalledApp(
    packageName: map['packageName'] as String? ?? '',
    label: map['label'] as String? ?? '',
    isSystem: map['system'] as bool? ?? false,
    isBackground: map['background'] as bool? ?? false,
  );
}

/// One member of an outbound group, with its last measured latency.
class OutboundItem {
  const OutboundItem({
    required this.tag,
    required this.type,
    required this.delayMs,
    required this.testedAt,
  });

  final String tag;
  final String type;

  /// Round-trip in milliseconds. Zero means never measured; a failed test also
  /// reports zero, which is why [testedAt] is needed to tell them apart.
  final int delayMs;

  /// Unix seconds of the last measurement, or 0 if never run.
  final int testedAt;

  bool get isMeasured => testedAt > 0;
  bool get isReachable => delayMs > 0;

  factory OutboundItem.fromMap(Map<Object?, Object?> map) => OutboundItem(
    tag: map['tag'] as String? ?? '',
    type: map['type'] as String? ?? '',
    delayMs: (map['delay'] as num?)?.toInt() ?? 0,
    testedAt: (map['testedAt'] as num?)?.toInt() ?? 0,
  );

  // Compared by value: the core republishes its groups every second whether or not a
  // reading moved, and only a real change is worth redrawing the server list for.
  @override
  bool operator ==(Object other) =>
      other is OutboundItem &&
      other.tag == tag &&
      other.type == type &&
      other.delayMs == delayMs &&
      other.testedAt == testedAt;

  @override
  int get hashCode => Object.hash(tag, type, delayMs, testedAt);
}

/// A selector or urltest group as the core sees it.
class OutboundGroup {
  const OutboundGroup({
    required this.tag,
    required this.type,
    required this.selected,
    required this.selectable,
    required this.items,
  });

  final String tag;
  final String type;

  /// The member currently carrying traffic.
  final String selected;

  /// False for urltest groups, which choose for themselves.
  final bool selectable;
  final List<OutboundItem> items;

  factory OutboundGroup.fromMap(Map<Object?, Object?> map) => OutboundGroup(
    tag: map['tag'] as String? ?? '',
    type: map['type'] as String? ?? '',
    selected: map['selected'] as String? ?? '',
    selectable: map['selectable'] as bool? ?? false,
    items: (map['items'] as List? ?? [])
        .map((e) => OutboundItem.fromMap((e as Map).cast<Object?, Object?>()))
        .toList(growable: false),
  );

  @override
  bool operator ==(Object other) =>
      other is OutboundGroup &&
      other.tag == tag &&
      other.type == type &&
      other.selected == selected &&
      other.selectable == selectable &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(tag, type, selected, selectable, Object.hashAll(items));
}

/// One connection the core currently has open.
class ActiveConnection {
  const ActiveConnection({
    required this.id,
    required this.network,
    required this.protocol,
    required this.domain,
    required this.destination,
    required this.outbound,
    required this.user,
    required this.packages,
    required this.uplink,
    required this.downlink,
    required this.createdAt,
  });

  final String id;
  final String network;
  final String protocol;

  /// Sniffed hostname, empty for connections made straight to an IP.
  final String domain;
  final String destination;

  /// Which outbound carried it — the quickest way to see a routing rule working.
  final String outbound;

  /// The inbound's authenticated user — not the app, whatever it looks like. The
  /// tunnel's own inbound has no authentication, so this is nearly always empty.
  final String user;

  /// The packages the core resolved as owning this connection, usually one.
  ///
  /// Empty unless something asked the core to look, which a `package_name` routing
  /// rule is what does. So this fills in for people who route by app and stays empty
  /// for everyone else, at no cost to either.
  final List<String> packages;

  /// The one app to name for this connection, or empty when the core did not say.
  /// A uid shared by several packages is rare enough that the first will do.
  String get appPackage => packages.isEmpty ? '' : packages.first;
  final int uplink;
  final int downlink;
  final int createdAt;

  String get target => domain.isNotEmpty ? domain : destination;

  factory ActiveConnection.fromMap(Map<Object?, Object?> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return ActiveConnection(
      id: map['id'] as String? ?? '',
      network: map['network'] as String? ?? '',
      protocol: map['protocol'] as String? ?? '',
      domain: map['domain'] as String? ?? '',
      destination: map['destination'] as String? ?? '',
      outbound: map['outbound'] as String? ?? '',
      user: map['user'] as String? ?? '',
      packages: [
        for (final name in (map['packages'] as List?) ?? const [])
          if (name is String && name.isNotEmpty) name,
      ],
      uplink: intOf('uplink'),
      downlink: intOf('downlink'),
      createdAt: intOf('createdAt'),
    );
  }
}

/// Throughput split by how routing sent the traffic out, in bytes per second.
///
/// The core's aggregate counters carry no breakdown by outbound, so this is summed
/// natively from the per-connection byte deltas — the only place that attribution
/// exists. "Direct" is what routing sent straight out; everything else went through
/// the tunnel, a chained WARP endpoint included.
class TrafficSplit {
  const TrafficSplit({
    this.directUp = 0,
    this.directDown = 0,
    this.proxyUp = 0,
    this.proxyDown = 0,
  });

  final int directUp;
  final int directDown;
  final int proxyUp;
  final int proxyDown;

  int get up => directUp + proxyUp;
  int get down => directDown + proxyDown;

  static const zero = TrafficSplit();

  factory TrafficSplit.fromMap(Map<Object?, Object?> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return TrafficSplit(
      directUp: intOf('directUp'),
      directDown: intOf('directDown'),
      proxyUp: intOf('proxyUp'),
      proxyDown: intOf('proxyDown'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrafficSplit &&
      other.directUp == directUp &&
      other.directDown == directDown &&
      other.proxyUp == proxyUp &&
      other.proxyDown == proxyDown;

  @override
  int get hashCode => Object.hash(directUp, directDown, proxyUp, proxyDown);
}
