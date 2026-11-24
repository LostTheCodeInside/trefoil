import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import 'config_builder.dart';
import 'outbound.dart';
import 'share_link.dart';

/// Quota and expiry, as reported by the provider.
///
/// Comes from the `Subscription-Userinfo` response header, a de-facto standard among
/// subscription providers:
///   `upload=455727941; download=6174315083; total=107374182400; expire=1671815872`
///
/// Every field is optional and providers disagree about which they send, so nothing
/// here is required and a missing value means "not reported" rather than zero.
class SubscriptionUsage {
  const SubscriptionUsage({this.upload, this.download, this.total, this.expiresAt});

  final int? upload;
  final int? download;
  final int? total;
  final DateTime? expiresAt;

  int? get used => (upload == null && download == null) ? null : (upload ?? 0) + (download ?? 0);

  /// Null when either side is unknown, or when the provider reports an unlimited
  /// plan as total = 0 — dividing by that would read as 100% used.
  double? get fraction {
    final consumed = used;
    final limit = total;
    if (consumed == null || limit == null || limit <= 0) return null;
    return (consumed / limit).clamp(0.0, 1.0);
  }

  int? get daysLeft => expiresAt?.difference(DateTime.now()).inDays;

  bool get isEmpty => upload == null && download == null && total == null && expiresAt == null;

  /// Parses the header value. Returns an empty instance rather than throwing: a
  /// provider sending something unexpected must not break the whole refresh.
  factory SubscriptionUsage.parse(String? header) {
    if (header == null || header.trim().isEmpty) return const SubscriptionUsage();
    final fields = <String, String>{};
    for (final part in header.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      fields[part.substring(0, index).trim().toLowerCase()] = part.substring(index + 1).trim();
    }
    int? number(String key) {
      final raw = fields[key];
      if (raw == null || raw.isEmpty) return null;
      final value = double.tryParse(raw);
      // Out of range is how some providers write "unlimited", and "Infinity" and "NaN"
      // both parse. None of them is a figure to show.
      if (value == null || !value.isFinite || value.abs() > _largestNumber) return null;
      return int.tryParse(raw) ?? value.round();
    }

    return SubscriptionUsage(
      upload: number('upload'),
      download: number('download'),
      total: number('total'),
      expiresAt: _expiry(number('expire')),
    );
  }

  /// An exabyte, which is also small enough for upload and download to be added up.
  static const _largestNumber = 1 << 60;

  /// Seconds since the epoch, or milliseconds from the providers that send those. Zero
  /// is how several say "never expires".
  static DateTime? _expiry(int? value) {
    if (value == null || value <= 0) return null;
    // The year 5138: no plan runs that long, so anything past it was not seconds.
    final milliseconds = value < 100000000000 ? value * 1000 : value;
    if (milliseconds > _lastDateTime) return null;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  /// As far as a [DateTime] reaches; anything later makes its constructor throw.
  static const _lastDateTime = 8640000000000000;

  Map<String, Object?> toJson() => {
    'upload': upload,
    'download': download,
    'total': total,
    'expiresAt': expiresAt?.toIso8601String(),
  };

  factory SubscriptionUsage.fromJson(Map<String, Object?> map) => SubscriptionUsage(
    upload: (map['upload'] as num?)?.toInt(),
    download: (map['download'] as num?)?.toInt(),
    total: (map['total'] as num?)?.toInt(),
    expiresAt: DateTime.tryParse(map['expiresAt'] as String? ?? ''),
  );
}

/// A subscription the user imported, kept so it can be refreshed later.
class Subscription {
  const Subscription({
    required this.id,
    required this.name,
    required this.url,
    this.updatedAt,
    this.usage = const SubscriptionUsage(),
  });

  final String id;
  final String name;
  final String url;
  final DateTime? updatedAt;

  /// Last reported quota. Kept between refreshes so it survives going offline.
  final SubscriptionUsage usage;

  Subscription copyWith({String? name, DateTime? updatedAt, SubscriptionUsage? usage}) =>
      Subscription(
        id: id,
        name: name ?? this.name,
        url: url,
        updatedAt: updatedAt ?? this.updatedAt,
        usage: usage ?? this.usage,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'updatedAt': updatedAt?.toIso8601String(),
    'usage': usage.toJson(),
  };

  factory Subscription.fromJson(Map<String, Object?> map) => Subscription(
    id: map['id'] as String? ?? '',
    name: map['name'] as String? ?? '',
    url: map['url'] as String? ?? '',
    updatedAt: DateTime.tryParse(map['updatedAt'] as String? ?? ''),
    usage: map['usage'] == null
        ? const SubscriptionUsage()
        : SubscriptionUsage.fromJson((map['usage'] as Map).cast<String, Object?>()),
  );
}

/// Everything the app persists: servers, subscriptions, and which server is selected.
///
/// Written as a single JSON document with a schema version. One document keeps the
/// three pieces consistent — a crash can never leave a selected tag pointing at a
/// server that was not saved.
class ProfileData {
  const ProfileData({
    this.servers = const [],
    this.subscriptions = const [],
    this.selectedTag,
    this.needsReimport = false,
    this.settings,
    this.localeCode,
    this.themeModeName = 'system',
    this.hapticFeedback = true,
    this.autoCheckIp = false,
    this.crashReports = false,
    this.insecureDownloads = false,
    this.damaged = false,
  });

  final List<Outbound> servers;
  final List<Subscription> subscriptions;
  final String? selectedTag;

  /// True when the servers were saved before the app kept share links.
  ///
  /// Those entries cannot be run on the Xray core: the parameters that decide it —
  /// `pqv` above all — were dropped at import time and only exist in the original
  /// link, which was not stored. They still work on sing-box, so they are kept, but
  /// a post-quantum REALITY server among them will silently fall back to sing-box
  /// and fail. Re-importing is the only way to recover the information.
  final bool needsReimport;

  /// Null for profiles written before settings were persisted; callers substitute
  /// the defaults.
  final ConfigBuilder? settings;

  /// Language override, or null to follow the system.
  final String? localeCode;

  /// `system`, `light` or `dark`. Stored as a name rather than an index so a
  /// reordering of the enum cannot silently change what an existing profile means.
  final String themeModeName;

  /// A short tick on connect, disconnect and mode changes.
  final bool hapticFeedback;

  /// Look up the public exit address after connecting.
  ///
  /// Off by default: it is a request to a third party that the user did not make, on
  /// behalf of someone who chose this app specifically to control where their traffic
  /// goes. Worth having, worth asking for.
  final bool autoCheckIp;

  /// Record uncaught errors to a local file.
  ///
  /// Nothing is sent anywhere — there is nowhere to send it. The file is the app's
  /// own, and the user chooses whether to share it.
  final bool crashReports;

  /// Accept any TLS certificate when fetching subscriptions and rule sets.
  ///
  /// Off by default. With it on, whatever answers the request can present its own
  /// certificate and the app will take the servers it hands back — which for a
  /// subscription means the credentials it runs on.
  final bool insecureDownloads;

  /// True when part of the saved document could not be read. Never written: it says
  /// something about this launch, so the user can be told once.
  final bool damaged;

  Outbound? get selected {
    if (servers.isEmpty) return null;
    for (final s in servers) {
      if (s.tag == selectedTag) return s;
    }
    // A stale or missing selection falls back to the first server rather than
    // leaving the user with a Connect button that cannot do anything.
    return servers.first;
  }

  ProfileData copyWith({
    List<Outbound>? servers,
    List<Subscription>? subscriptions,
    String? selectedTag,
    bool? needsReimport,
    ConfigBuilder? settings,
    String? localeCode,
    String? themeModeName,
    bool? hapticFeedback,
    bool? autoCheckIp,
    bool? crashReports,
    bool? insecureDownloads,
    bool clearLocale = false,
  }) => ProfileData(
    servers: servers ?? this.servers,
    subscriptions: subscriptions ?? this.subscriptions,
    selectedTag: selectedTag ?? this.selectedTag,
    needsReimport: needsReimport ?? this.needsReimport,
    settings: settings ?? this.settings,
    // Separate flag: null means "unchanged" for every other field here, but for a
    // locale it is also a real value — follow the system.
    localeCode: clearLocale ? null : (localeCode ?? this.localeCode),
    themeModeName: themeModeName ?? this.themeModeName,
    hapticFeedback: hapticFeedback ?? this.hapticFeedback,
    autoCheckIp: autoCheckIp ?? this.autoCheckIp,
    crashReports: crashReports ?? this.crashReports,
    insecureDownloads: insecureDownloads ?? this.insecureDownloads,
    damaged: damaged,
  );
}

/// Reads and writes [ProfileData] on disk.
class ProfileStore {
  /// [directory] overrides where the document lives; the app leaves it unset and
  /// gets the platform's app-support directory. Tests point it at a temp directory
  /// so they exercise the real read and write path rather than a stand-in.
  ProfileStore({Directory? directory}) : _override = directory;

  static final ProfileStore instance = ProfileStore();

  final Directory? _override;

  /// v2 added the original share link and the Xray flag to each server.
  /// v3 persists tunnel settings, which until then lived only in memory.
  /// v4 reads every share link again, since until then some were read wrong.
  static const _schemaVersion = 4;
  static const _fileName = 'profiles.json';

  File? _file;

  /// Writes are chained, never concurrent.
  ///
  /// Every write goes through one fixed temp path, so two overlapping saves
  /// interleave into the same file and the rename publishes the result -- a profile
  /// with half of one document and half of another, which reads back on the next
  /// launch as no servers at all. Saves are triggered from several independent
  /// places (a background subscription refresh and a user edit, most obviously), so
  /// overlapping is not hypothetical.
  Future<void> _writes = Future<void>.value();

  Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = _override ?? await getApplicationSupportDirectory();
    return _file = File('${dir.path}/$_fileName');
  }

  /// The whole document as a map — the same shape written to disk, and what a
  /// backup carries.
  Map<String, Object?> encode(ProfileData data) => {
    'version': _schemaVersion,
    'servers': data.servers.map((e) => e.toStorage()).toList(),
    'subscriptions': data.subscriptions.map((e) => e.toJson()).toList(),
    'selectedTag': data.selectedTag,
    'settings': data.settings?.toJson(),
    'localeCode': data.localeCode,
    'themeMode': data.themeModeName,
    'hapticFeedback': data.hapticFeedback,
    'autoCheckIp': data.autoCheckIp,
    'crashReports': data.crashReports,
    'insecureDownloads': data.insecureDownloads,
  };

  /// Rejects a document from a newer schema rather than silently dropping the fields it
  /// does not understand, and one that cannot be read in full.
  ///
  /// Given [problems], it keeps what it can instead and says there what it could not:
  /// one unreadable server is no reason to lose the others.
  ProfileData decode(Map<String, Object?> map, {List<Object>? problems}) {
    T? attempt<T>(T? Function() read) {
      try {
        return read();
      } catch (e) {
        if (problems == null) rethrow;
        problems.add(e);
        return null;
      }
    }

    List<T> each<T>(String key, T Function(Map<String, Object?> map) read) => [
      for (final entry in attempt(() => map[key] as List?) ?? const [])
        ?attempt(() => read((entry as Map).cast<String, Object?>())),
    ];

    final version = attempt(() => (map['version'] as num?)?.toInt()) ?? 0;
    if (version > _schemaVersion) {
      if (problems == null) throw const BackupTooNewException();
      problems.add(const BackupTooNewException());
    }
    final servers = each('servers', Outbound.fromStorage);
    return ProfileData(
      // Up to 1.1.2 a subscription refresh could save two servers under one name,
      // which the core refuses to start with. Such a profile is mended as it loads.
      servers: Outbound.withUniqueTags(
        version < 4 ? [for (final server in servers) _readAgain(server)] : servers,
      ),
      subscriptions: each('subscriptions', Subscription.fromJson),
      selectedTag: attempt(() => map['selectedTag'] as String?),
      needsReimport: version < 2 && servers.isNotEmpty,
      settings: attempt(
        () => map['settings'] == null
            ? null
            : ConfigBuilder.fromJson((map['settings'] as Map).cast<String, Object?>()),
      ),
      localeCode: attempt(() => map['localeCode'] as String?),
      themeModeName: attempt(() => map['themeMode'] as String?) ?? 'system',
      hapticFeedback: attempt(() => map['hapticFeedback'] as bool?) ?? true,
      autoCheckIp: attempt(() => map['autoCheckIp'] as bool?) ?? false,
      crashReports: attempt(() => map['crashReports'] as bool?) ?? false,
      insecureDownloads: attempt(() => map['insecureDownloads'] as bool?) ?? false,
      damaged: problems != null && problems.isNotEmpty,
    );
  }

  /// The server its own link describes, as it is read today.
  ///
  /// A subscription is read again every half a day, but a server added by hand keeps
  /// whatever the parser made of its link at the time — a `+` in a key read as a space,
  /// say — for good. Its name and where it came from are the user's, and stay.
  static Outbound _readAgain(Outbound stored) {
    final link = stored.link;
    final parsed = link == null ? null : ShareLink.parse(link);
    if (parsed == null || parsed.type != stored.type) return stored;
    return parsed.copyWith(tag: stored.tag, subscriptionId: stored.subscriptionId, link: link);
  }

  /// Reads the saved document, or as much of it as is readable.
  ///
  /// Parsing lives entirely in [decode] — this used to repeat it, and a field added
  /// to one and not the other is exactly the kind of bug that only shows up as
  /// settings quietly not surviving a restart.
  Future<ProfileData> load() async {
    final File file;
    try {
      file = await _resolveFile();
      if (!file.existsSync()) return const ProfileData();
    } catch (_) {
      return const ProfileData();
    }
    final problems = <Object>[];
    ProfileData data;
    var version = _schemaVersion;
    try {
      final map = (await _decodeOffThread(await file.readAsString())).cast<String, Object?>();
      data = decode(map, problems: problems);
      if (map['version'] case final num value) version = value.toInt();
    } catch (_) {
      // A corrupt file must not brick the app: start clean.
      data = const ProfileData(damaged: true);
    }
    if (data.damaged) {
      await _setAside(file);
    } else if (version < _schemaVersion && !data.needsReimport) {
      // Written back now, so the upgrade is done once rather than on every launch
      // until something else happens to save. Not for a profile that still has to be
      // imported again: the old version is what says so.
      save(data).ignore();
    }
    return data;
  }

  /// Keeps a copy of a document that could not be read in full.
  ///
  /// The next save replaces it, and until this existed a damaged file was every server
  /// gone for good. One copy, the latest; an empty file has nothing worth keeping.
  Future<void> _setAside(File file) async {
    try {
      if (file.lengthSync() > 0) await file.copy('${file.path}.corrupt');
    } catch (_) {
      // Storage that cannot be written to. There is nothing else to try.
    }
  }

  /// Temp-then-rename, so an interrupted write can never leave a half-written file
  /// that would read back as "no servers" on the next launch.
  ///
  /// Serialised behind [_writes]: see the note there.
  Future<void> save(ProfileData data) {
    final next = _writes.then((_) => _write(data));
    // The chain must survive a failed write, or one error would block every
    // subsequent save for the life of the process. The caller still sees it.
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> _write(ProfileData data) async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    // Encoded by [encode], not by a second copy of it. The copy that used to live
    // here had drifted: it never wrote `localeCode`, so a chosen language was
    // dropped on every save and the app reverted to the system language on the next
    // launch. A backup, which does go through [encode], kept the field -- which is
    // exactly the kind of split-brain this now cannot have.
    await temp.writeAsString(await _encodeOffThread(encode(data)), flush: true);
    await temp.rename(file.path);
  }

  // JSON for a few thousand servers runs to megabytes, and on the UI isolate every
  // millisecond of it is a dropped frame: at launch, and again on every save. Both
  // helpers are static so the closure they hand over carries nothing but its input.

  static Future<Map<Object?, Object?>> _decodeOffThread(String text) =>
      Isolate.run(() => jsonDecode(text) as Map<Object?, Object?>);

  static Future<String> _encodeOffThread(Map<String, Object?> document) =>
      Isolate.run(() => jsonEncode(document));
}

/// A backup written by a newer version of the app, whose fields this one would drop.
class BackupTooNewException implements Exception {
  const BackupTooNewException();

  @override
  String toString() => 'This backup was made by a newer version of the app';
}

/// Why a subscription produced no servers, in terms the UI can put into words: the
/// provider refused ([status]), the body was not a server list ([tooLarge]), or it
/// was one with nothing usable in it.
class SubscriptionException implements Exception {
  const SubscriptionException.http(int this.status) : tooLarge = false;
  const SubscriptionException.tooLarge() : status = null, tooLarge = true;
  const SubscriptionException.empty() : status = null, tooLarge = false;

  final int? status;
  final bool tooLarge;

  @override
  String toString() => switch (this) {
    SubscriptionException(:final status?) => 'Subscription returned HTTP $status',
    SubscriptionException(tooLarge: true) =>
      'That subscription is far too large to be a server list',
    _ => 'No usable servers found in this subscription',
  };
}

/// Fetches a subscription URL and parses it into servers.
class SubscriptionFetcher {
  /// Parsed on another isolate. A provider's Clash document can run to megabytes of
  /// YAML, and parsing it where the UI runs froze the screen for as long as it took —
  /// on every launch, since stale subscriptions refresh then. Static, so the closure
  /// carries the two strings and nothing else.
  static Future<List<Outbound>> _parseOffThread(String body, String subscriptionId) =>
      Isolate.run(() => ShareLink.parseSubscription(body, subscriptionId: subscriptionId));

  const SubscriptionFetcher({
    this.timeout = const Duration(seconds: 20),
    this.allowInsecure = false,
  });

  final Duration timeout;

  /// Accept any certificate. See ProfileData.insecureDownloads for what that costs.
  final bool allowInsecure;

  /// The largest body worth reading.
  ///
  /// A subscription is a list of share links; even a very generous provider is a few
  /// hundred kilobytes. Without a ceiling the response is read into memory in full,
  /// so a mistyped URL pointing at a large file -- or a hostile server that simply
  /// never stops sending -- takes the app down with an out-of-memory kill.
  static const maxBodyBytes = 8 * 1024 * 1024;

  /// The servers, plus whatever quota the provider reported alongside them.
  Future<({List<Outbound> servers, SubscriptionUsage usage})> fetch(
    String url, {
    required String subscriptionId,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    if (allowInsecure) client.badCertificateCallback = (_, _, _) => true;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      // Some providers serve a different body, or refuse entirely, without a
      // recognised client user-agent.
      request.headers.set(HttpHeaders.userAgentHeader, 'Trefoil/1.0 (sing-box)');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw SubscriptionException.http(response.statusCode);
      }
      // Read before draining the body: the quota lives in a response header.
      final usage = SubscriptionUsage.parse(response.headers.value('subscription-userinfo'));

      if (response.contentLength > maxBodyBytes) throw const SubscriptionException.tooLarge();
      // Counted on the raw bytes and decoded afterwards, so a multi-byte character
      // split across two chunks still decodes correctly.
      var received = 0;
      final body = await response
          .map((chunk) {
            received += chunk.length;
            if (received > maxBodyBytes) throw const SubscriptionException.tooLarge();
            return chunk;
          })
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final servers = await _parseOffThread(body, subscriptionId);
      if (servers.isEmpty) throw const SubscriptionException.empty();
      return (servers: servers, usage: usage);
    } finally {
      client.close(force: true);
    }
  }
}
