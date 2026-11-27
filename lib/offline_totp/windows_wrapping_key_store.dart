import 'package:flutter/services.dart';

import 'secret_store.dart';

/// Wrapping-key store backed by the generated Windows host's native overlay
/// (direct DPAPI, create-only file publish). Key-only: every name is a
/// per-install namespace holding exactly one 32-byte opaque key.
///
/// Replies are validated strictly. A malformed reply to a mutation is treated
/// as an unknown outcome, never as success or as absence.
final class WindowsWrappingKeyStore implements SecretStore {
  WindowsWrappingKeyStore([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('app.otpanda/wrapping-key');

  static const keyBytes = 32;
  final MethodChannel _channel;
  static final _name = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  @override
  String get kind => 'windows-dpapi';

  static void _checkName(String name) {
    if (!_name.hasMatch(name)) {
      throw const SecretStoreException(SecretStoreError.unavailable);
    }
  }

  /// Mutation errors are trusted as "known not applied" only when the native
  /// side sent a recognised code AND details exactly {outcomeUnknown: bool}.
  /// Anything missing, malformed or extra means the outcome is unknown.
  SecretStoreException _mapPlatform(
    PlatformException e, {
    required bool mutating,
  }) {
    final error = switch (e.code) {
      'denied' => SecretStoreError.denied,
      'corrupt' => SecretStoreError.corrupt,
      _ => SecretStoreError.unavailable,
    };
    if (!mutating) return SecretStoreException(error);
    final known =
        e.code == 'denied' || e.code == 'corrupt' || e.code == 'unavailable';
    final d = e.details;
    final wellFormed = d is Map && d.length == 1 && d['outcomeUnknown'] is bool;
    final unknown = !known || !wellFormed || d['outcomeUnknown'] == true;
    return SecretStoreException(error, outcomeUnknown: unknown);
  }

  Map<Object?, Object?> _reply(
    Object? v,
    Set<String> keys, {
    required bool mutating,
  }) {
    if (v is! Map || v.length != keys.length || !keys.every(v.containsKey)) {
      throw SecretStoreException(
        SecretStoreError.unavailable,
        outcomeUnknown: mutating,
      );
    }
    return v;
  }

  Future<T> _call<T>(
    String method,
    Map<String, Object?> args, {
    required bool mutating,
    required T Function(Object? reply) parse,
  }) async {
    try {
      final reply = await _channel.invokeMethod<Object?>(method, args);
      return parse(reply);
    } on SecretStoreException {
      rethrow;
    } on PlatformException catch (e) {
      throw _mapPlatform(e, mutating: mutating);
    } on MissingPluginException {
      // The call never reached native code, so nothing was applied.
      throw const SecretStoreException(SecretStoreError.unavailable);
    } catch (_) {
      // Codec, cast or parse failures after a call started: a mutation may
      // have landed.
      throw SecretStoreException(
        SecretStoreError.unavailable,
        outcomeUnknown: mutating,
      );
    }
  }

  @override
  Future<Uint8List?> read(String name) async {
    _checkName(name);
    return await _call(
      'wrappingKeyRead',
      {'namespace': name},
      mutating: false,
      parse: (r) {
        final key = _reply(r, {'key'}, mutating: false)['key'];
        if (key == null) return null;
        if (key is! Uint8List || key.length != keyBytes) {
          throw const SecretStoreException(SecretStoreError.corrupt);
        }
        return Uint8List.fromList(key);
      },
    );
  }

  @override
  Future<Uint8List> createIfAbsent(String name, Uint8List candidate) async {
    _checkName(name);
    if (candidate.length != keyBytes) {
      throw const SecretStoreException(SecretStoreError.unavailable);
    }
    return await _call(
      'wrappingKeyCreate',
      {'namespace': name, 'key': candidate},
      mutating: true,
      parse: (r) {
        final m = _reply(r, {'key', 'created'}, mutating: true);
        final key = m['key'];
        if (key is! Uint8List ||
            key.length != keyBytes ||
            m['created'] is! bool) {
          throw const SecretStoreException(
            SecretStoreError.unavailable,
            outcomeUnknown: true,
          );
        }
        return Uint8List.fromList(key);
      },
    );
  }

  @override
  Future<void> delete(String name) async {
    _checkName(name);
    await _call(
      'wrappingKeyDelete',
      {'namespace': name},
      mutating: true,
      parse: (r) {
        _reply(r, {}, mutating: true);
      },
    );
  }
}
