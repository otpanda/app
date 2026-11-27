import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'directory_store.dart';
import 'public_service_catalog.dart';

/// Where the data and icons come from. The catalogue is the 2FA Directory v3
/// API (MIT, attribution required: "Data sourced from 2FA Directory by
/// 2factorauth"). Icons are the files its catalogue names, in its public
/// repository; their authors keep the rights to them. This is cosmetic
/// lookup only: nothing here feeds autofill, code release or trust.
const directoryCatalogUrl = 'https://api.2fa.directory/v3/all.json';
const directoryIconBase =
    'https://raw.githubusercontent.com/2factorauth/twofactorauth/master/img/';

class DirectoryLimits {
  static const catalogBytes = 2 * 1024 * 1024;
  static const catalogRows = 6000;
  static const logoBytes = 64 * 1024;
  static const svgElements = 1500;
  static const pngSide = 256;
  static const logoEntries = 400;
  static const logoStoreBytes = 2 * 1024 * 1024;
  static const concurrentFetches = 4;
  static const fetchTimeout = Duration(seconds: 10);
  // The upstream API sends Cache-Control: max-age=604800 and asks clients to
  // cache locally. A week is the same window.
  static const catalogTtl = Duration(days: 7);
  static const logoTtl = Duration(days: 30);
  static const failureBackoff = Duration(hours: 1);
}

/// One catalogue row. [hosts] holds the primary domain first, then the
/// additional domains the directory lists, unchanged. They are kept as data
/// and are not used for logo lookup.
class DirectoryService {
  final String name;
  final List<String> hosts;
  final String icon;
  const DirectoryService(this.name, this.hosts, this.icon);
  String get host => hosts.first;
  Map<String, Object> toJson() => {'n': name, 'd': hosts, 'i': icon};
}

final _hostRe = RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$');
final _iconRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.(svg|png)$');
bool isValidIconName(String s) => _iconRe.hasMatch(s) && !s.contains('..');
final _ctrlRe = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]',
);

String normalizeServiceName(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Parses the upstream v3 file: a JSON array of [name, {domain, img?,
/// additional-domains?, ...}] pairs. Rows that fail validation are skipped
/// rather than failing the file; an empty result is an error.
List<DirectoryService> parseUpstreamCatalog(String text) {
  if (text.length > DirectoryLimits.catalogBytes) {
    throw const FormatException('Catalogue too large');
  }
  final data = jsonDecode(text);
  if (data is! List ||
      data.isEmpty ||
      data.length > DirectoryLimits.catalogRows) {
    throw const FormatException('Catalogue shape');
  }
  final out = <DirectoryService>[];
  for (final row in data) {
    if (row is! List || row.length != 2) continue;
    final name = row[0], v = row[1];
    if (name is! String || v is! Map) continue;
    if (name.trim().isEmpty || name.length > 120 || _ctrlRe.hasMatch(name)) {
      continue;
    }
    final domain = v['domain'];
    if (domain is! String || !_hostRe.hasMatch(domain) || domain.length > 253) {
      continue;
    }
    final hosts = <String>[domain];
    final extra = v['additional-domains'];
    if (extra is List) {
      for (final h in extra) {
        if (h is String &&
            _hostRe.hasMatch(h) &&
            h.length <= 253 &&
            !hosts.contains(h) &&
            hosts.length < 40) {
          hosts.add(h);
        }
      }
    }
    final img = v['img'];
    final icon = img is String ? img : '$domain.svg';
    out.add(DirectoryService(name, hosts, isValidIconName(icon) ? icon : ''));
  }
  if (out.isEmpty) throw const FormatException('No usable rows');
  return out;
}

enum LogoKind { svg, png }

class LogoImage {
  final LogoKind kind;
  final Uint8List bytes;
  const LogoImage(this.kind, this.bytes);
}

final _pngSig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
final _svgDeny = RegExp(
  r'<\s*(script|foreignObject|iframe|object|embed|image|audio|video|link|meta|animate|set)\b'
  r'|<!\s*(DOCTYPE|ENTITY)|<\?(?!xml)'
  r'|\bon[a-z]+\s*='
  r'|javascript:|data:text|@import|(?:xlink:)?href\s*=\s*["\x27](?!#)'
  r'|url\(\s*["\x27]?\s*(?!#)',
  caseSensitive: false,
);

/// Returns the image when [bytes] is a small SVG with none of the elements
/// or references we refuse, or a small PNG with sane dimensions. Anything else
/// is null (letter fallback). This bounds what reaches the renderer; it is
/// not a sanitizer for arbitrary SVG.
LogoImage? validateLogo(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > DirectoryLimits.logoBytes) return null;
  if (bytes.length >= 33 && listEquals(bytes.sublist(0, 8), _pngSig)) {
    final b = ByteData.sublistView(bytes);
    if (String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') return null;
    final w = b.getUint32(16), h = b.getUint32(20);
    if (w < 1 ||
        h < 1 ||
        w > DirectoryLimits.pngSide ||
        h > DirectoryLimits.pngSide) {
      return null;
    }
    return LogoImage(LogoKind.png, bytes);
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  final head = text.trimLeft();
  if (!(head.startsWith('<svg') ||
      head.startsWith('<?xml') ||
      head.startsWith('<!--'))) {
    return null;
  }
  if (!RegExp(r'<svg[\s>]').hasMatch(text)) return null;
  if (_svgDeny.hasMatch(text)) return null;
  if ('<'.allMatches(text).length > DirectoryLimits.svgElements) return null;
  return LogoImage(LogoKind.svg, bytes);
}

/// Loads the catalogue and logos with a bounded, offline-tolerant cache.
///
/// Catalogue: fresh cache (under [DirectoryLimits.catalogTtl]) is used as is.
/// Otherwise one conditional GET (ETag). On 304 the cache is kept and
/// re-stamped; on 200 it is replaced only after the new file parses; on any
/// failure the last good cache is kept, even if stale. With no cache at all
/// the bundled snapshot is used. Logos: per-icon cache with a 30 day TTL,
/// last-good on failure, a count and byte bound with oldest-first eviction.
class ServiceDirectory extends ChangeNotifier {
  final http.Client Function() _newClient;
  final DirectoryStore? _store;
  final DateTime Function() _now;
  final Future<String> Function() _bundledText;

  ServiceDirectory({
    http.Client Function()? client,
    DirectoryStore? store,
    bool useDefaultStore = true,
    DateTime Function()? now,
    Future<String> Function()? bundledText,
  }) : _newClient = client ?? http.Client.new,
       _store = store ?? (useDefaultStore ? _safeStore() : null),
       _now = now ?? DateTime.now,
       _bundledText =
           bundledText ??
           (() => rootBundle.loadString('assets/service-catalog.json'));

  static DirectoryStore? _safeStore() {
    try {
      return createDirectoryStore();
    } catch (_) {
      return null;
    }
  }

  static ServiceDirectory instance = ServiceDirectory();

  Map<String, DirectoryService?> _byName = const {};
  Map<String, DirectoryService?> _byHost = const {};
  bool _loaded = false;
  Future<void>? _loading;
  Future<void>? _activeLoad;
  bool _forceRequested = false, _fetchingCatalog = false;
  final _ready = Completer<void>();
  String source = 'none'; // cache | network | bundled | none
  int fetchedAtMs = 0;
  http.Client? _client;

  List<DirectoryService> _rows = const [];
  List<DirectoryService> get services => _rows;
  bool get loaded => _loaded;

  /// Idempotent; safe to call from every avatar. Never throws.
  Future<void> ensureLoaded() => _loading ??= _startLoad();

  /// Completes once the cache (or the bundled snapshot) is in place, without
  /// waiting for the network. UI that must not hang on a slow connection
  /// waits for this; the refresh then lands through the listeners.
  Future<void> ensureReady() {
    ensureLoaded();
    return _ready.future;
  }

  Future<void> refresh() {
    // Upgrade a cache-read flight before its freshness decision. If its GET
    // already started, join that GET instead of queuing another one.
    if (_activeLoad != null && !_fetchingCatalog) _forceRequested = true;
    _loading = _activeLoad ?? _startLoad(force: true);
    return _loading!;
  }

  Future<void> _startLoad({bool force = false}) {
    late final Future<void> operation;
    operation = _load(force: force).whenComplete(() {
      if (identical(_activeLoad, operation)) {
        _activeLoad = null;
        _forceRequested = false;
        _fetchingCatalog = false;
      }
    });
    _activeLoad = operation;
    return operation;
  }

  Future<void> _load({bool force = false}) async {
    List<DirectoryService>? cached;
    String? etag;
    var at = 0;
    try {
      final raw = await _store?.read('catalog.json');
      if (raw != null && raw.length <= DirectoryLimits.catalogBytes) {
        final m = jsonDecode(utf8.decode(raw));
        if (m is Map && m['at'] is int && m['rows'] is List) {
          final rows = <DirectoryService>[];
          for (final r in m['rows'] as List) {
            if (r is! Map) continue;
            final n = r['n'], d = r['d'], i = r['i'];
            if (n is! String || d is! List || d.isEmpty || i is! String) {
              continue;
            }
            final hosts = d
                .whereType<String>()
                .where(_hostRe.hasMatch)
                .toList();
            if (hosts.isEmpty) continue;
            rows.add(
              DirectoryService(
                n,
                hosts,
                i.isEmpty || isValidIconName(i) ? i : '',
              ),
            );
          }
          if (rows.isNotEmpty) {
            cached = rows;
            at = m['at'] as int;
            etag = m['etag'] is String ? m['etag'] as String : null;
          }
        }
      }
    } catch (_) {}
    if (cached != null) {
      _apply(cached, 'cache', at);
    } else if (_rows.isEmpty) {
      await _applyBundled();
    }
    if (!_ready.isCompleted) _ready.complete();
    final age = _now().millisecondsSinceEpoch - at;
    final fresh =
        cached != null &&
        age >= 0 &&
        age < DirectoryLimits.catalogTtl.inMilliseconds;
    final fetch = !fresh || force || _forceRequested;
    _forceRequested = false;
    if (fetch) {
      _fetchingCatalog = true;
      await _fetchCatalog(cached, etag);
    }
    _loaded = true;
    notifyListeners();
    // A synchronous completion listener can explicitly request refresh after
    // the freshness decision but before this flight has returned.
    if (_forceRequested && !_fetchingCatalog) {
      _forceRequested = false;
      _fetchingCatalog = true;
      await _fetchCatalog(cached, etag);
      notifyListeners();
    }
  }

  Future<void> _applyBundled() async {
    try {
      final c = PublicServiceCatalog.parse(await _bundledText());
      _apply(
        [
          for (final s in c.services)
            DirectoryService(s.name, [
              s.host,
            ], isValidIconName('${s.host}.svg') ? '${s.host}.svg' : ''),
        ],
        'bundled',
        c.fetchedAt,
      );
    } catch (_) {}
  }

  Future<void> _fetchCatalog(
    List<DirectoryService>? cached,
    String? etag,
  ) async {
    try {
      final c = _client ??= _newClient();
      final req = http.Request('GET', Uri.parse(directoryCatalogUrl))
        ..headers['accept'] = 'application/json';
      if (cached != null && etag != null) req.headers['if-none-match'] = etag;
      final res = await c.send(req).timeout(DirectoryLimits.fetchTimeout);
      if (res.statusCode == 304 && cached != null) {
        await _saveCatalog(cached, etag);
        _apply(cached, 'cache', _now().millisecondsSinceEpoch);
        return;
      }
      if (res.statusCode != 200) return;
      final body = await _readCapped(res, DirectoryLimits.catalogBytes);
      if (body == null) return;
      final rows = parseUpstreamCatalog(utf8.decode(body));
      final tag = res.headers['etag'];
      await _saveCatalog(rows, tag);
      _apply(rows, 'network', _now().millisecondsSinceEpoch);
    } catch (_) {
      // Keep whatever is loaded (last good cache) and try again next launch.
    }
  }

  Future<void> _saveCatalog(List<DirectoryService> rows, String? etag) async {
    try {
      final out = utf8.encode(
        jsonEncode({
          'at': _now().millisecondsSinceEpoch,
          'etag': ?etag,
          'rows': [for (final r in rows) r.toJson()],
        }),
      );
      await _store?.write('catalog.json', Uint8List.fromList(out));
    } catch (_) {}
  }

  void _apply(List<DirectoryService> rows, String src, int at) {
    final idx = <String, DirectoryService?>{};
    for (final r in rows) {
      final k = normalizeServiceName(r.name);
      // Exact normalised name only. A name two rows share is ambiguous and
      // resolves to nothing rather than to the first one.
      idx[k] = idx.containsKey(k) ? null : r;
    }
    final hosts = <String, DirectoryService?>{};
    for (final r in rows) {
      // Primary domain only: it is the service id the server stores. A host
      // that two rows share resolves to nothing.
      hosts[r.host] = hosts.containsKey(r.host) ? null : r;
    }
    _rows = List.unmodifiable(rows);
    _byName = idx;
    _byHost = hosts;
    source = src;
    fetchedAtMs = at;
    notifyListeners();
  }

  /// Exact, unambiguous match on the trimmed, case-folded name. No substring,
  /// no fuzzy search, no domain guessing.
  DirectoryService? lookup(String? service) {
    if (service == null) return null;
    final r = _byName[normalizeServiceName(service)];
    return r != null && r.icon.isNotEmpty ? r : null;
  }

  /// Persisted identity first: the entry's stored service id (the catalogue's
  /// primary domain) or website host, exact match on a listed primary domain.
  /// Renaming an entry's label does not change it. With no identity that
  /// resolves, fall back to the exact name. 'custom-totp' and anything that is
  /// not a plain host never match.
  DirectoryService? resolve({String? serviceId, String? host, String? name}) {
    for (final id in [serviceId, host]) {
      if (id == null || !_hostRe.hasMatch(id)) {
        continue;
      }
      final r = _byHost[id];
      if (r != null && r.icon.isNotEmpty) {
        return r;
      }
    }
    return lookup(name);
  }

  // ---- logos ----

  final _logos = <String, LogoImage>{};
  final _failedAt = <String, DateTime>{};
  final _inflight = <String, Future<LogoImage?>>{};
  final _queue = Queue<Completer<void>>();
  var _active = 0;

  LogoImage? cachedLogo(String icon) => _logos[icon];

  Future<LogoImage?> logo(String icon) {
    if (!isValidIconName(icon)) return Future.value();
    final hit = _logos[icon];
    if (hit != null) return Future.value(hit);
    final failed = _failedAt[icon];
    if (failed != null &&
        _now().difference(failed) < DirectoryLimits.failureBackoff) {
      return Future.value();
    }
    return _inflight[icon] ??= _loadLogo(icon).whenComplete(() {
      _inflight.remove(icon);
    });
  }

  Future<LogoImage?> _loadLogo(String icon) async {
    final key = 'logo-$icon';
    LogoImage? stale;
    try {
      final raw = await _store?.read(key);
      if (raw != null) {
        final v = validateLogo(raw);
        if (v != null) {
          stale = v;
          final item = (await _store!.list())
              .where((e) => e.key == key)
              .firstOrNull;
          final age = item == null
              ? 1 << 62
              : _now().millisecondsSinceEpoch - item.modifiedMs;
          if (age >= 0 && age < DirectoryLimits.logoTtl.inMilliseconds) {
            return _logos[icon] = v;
          }
        }
      }
    } catch (_) {}
    await _slot();
    try {
      final fetched = await _fetchLogo(icon);
      if (fetched != null) {
        _logos[icon] = fetched;
        try {
          await _store?.write(key, fetched.bytes);
          await _evict();
        } catch (_) {}
        return fetched;
      }
    } finally {
      _release();
    }
    if (stale != null) return _logos[icon] = stale;
    _failedAt[icon] = _now();
    return null;
  }

  Future<LogoImage?> _fetchLogo(String icon) async {
    try {
      final c = _client ??= _newClient();
      final res = await c
          .send(
            http.Request(
              'GET',
              Uri.parse('$directoryIconBase${icon[0]}/$icon'),
            ),
          )
          .timeout(DirectoryLimits.fetchTimeout);
      if (res.statusCode != 200) return null;
      final type = (res.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      if (type != 'image/svg+xml' && type != 'image/png') return null;
      final body = await _readCapped(res, DirectoryLimits.logoBytes);
      if (body == null) return null;
      final v = validateLogo(body);
      if (v == null) return null;
      if ((v.kind == LogoKind.svg) != (type == 'image/svg+xml')) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _readCapped(http.StreamedResponse res, int cap) async {
    final len = res.contentLength;
    if (len != null && len > cap) return null;
    final out = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(
      DirectoryLimits.fetchTimeout,
    )) {
      out.add(chunk);
      if (out.length > cap) return null;
    }
    return out.takeBytes();
  }

  Future<void> _slot() {
    if (_active < DirectoryLimits.concurrentFetches) {
      _active++;
      return Future.value();
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      _active--;
    }
  }

  Future<void> _evict() async {
    final s = _store;
    if (s == null) return;
    final items =
        (await s.list()).where((e) => e.key.startsWith('logo-')).toList()
          ..sort((a, b) => a.modifiedMs.compareTo(b.modifiedMs));
    var bytes = items.fold<int>(0, (n, e) => n + e.size);
    var count = items.length;
    for (final e in items) {
      if (count <= DirectoryLimits.logoEntries &&
          bytes <= DirectoryLimits.logoStoreBytes) {
        break;
      }
      await s.delete(e.key);
      count--;
      bytes -= e.size;
    }
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}
