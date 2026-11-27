import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// Install-only store, independent of account/session state. No erase method.
/// createIfAbsent must atomically return the persisted winner, not overwrite it.
abstract interface class SeedInstallIdStore {
  Future<String?> read();
  Future<String> createIfAbsent(String candidate);
}

/// Dart generates the random id. Native persistence is create-only and excluded
/// from backup/transfer. A corrupt/unavailable store is a retry, never a new id.
final class SeedInstallId {
  SeedInstallId(this.store, {Random? random})
    : _random = random ?? Random.secure();
  final SeedInstallIdStore store;
  final Random _random;
  Future<String>? _running;
  String? _cached;
  static final _valid = RegExp(r'^[A-Za-z0-9_-]{22,64}$');

  String _check(String id) {
    if (!_valid.hasMatch(id)) throw const FormatException('invalid install id');
    return id;
  }

  Future<String> get() {
    if (_cached != null) return Future.value(_cached!);
    return _running ??= _load().whenComplete(() {
      _running = null;
    });
  }

  Future<String> _load() async {
    final saved = await store.read();
    if (saved != null) return _cached = _check(saved);
    final candidate = base64UrlEncode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    final persisted = _check(await store.createIfAbsent(candidate));
    // Another process may have won create-if-absent. Its valid value is final.
    return _cached = persisted;
  }
}
