import 'package:flutter/services.dart';

import 'seed_status_coordinator.dart';

/// Inactive adapter. The caller supplies the channel; no host is registered here.
/// Discovery uses the native durable-state snapshot, not session state or a
/// separately reconstructed Dart owner list. Key is rechecked before each proof.
final class SeedStatusChannel implements SeedStatusNative {
  SeedStatusChannel(this.channel);
  final MethodChannel channel;

  Map<Object?, Object?> _map(Object? value, Set<String> keys) {
    if (value is! Map ||
        value.length != keys.length ||
        !keys.every(value.containsKey)) {
      throw const FormatException('invalid native status reply');
    }
    return value;
  }

  @override
  Future<SeedStatusOwners> owners() async {
    final m = _map(
      await channel.invokeMethod<Object?>('syncDiscoverOwners', {}),
      {'owners', 'unreadable', 'complete'},
    );
    if (m['owners'] is! List ||
        m['unreadable'] is! int ||
        (m['unreadable'] as int) < 0 ||
        m['complete'] is! bool) {
      throw const FormatException('invalid native discovery');
    }
    var incomplete = m['complete'] != true || m['unreadable'] != 0;
    final owners = <String>[];
    final seen = <String>{};
    for (final raw in m['owners'] as List) {
      final row = _map(raw, {'owner', 'keyId', 'pending'});
      final owner = row['owner'], key = row['keyId'];
      if (owner is! String ||
          owner.isEmpty ||
          !seen.add(owner) ||
          row['pending'] is! bool ||
          (key != null && key is! String)) {
        throw const FormatException('invalid native owner');
      }
      if (row['pending'] == true) {
        incomplete = true;
        continue;
      }
      if (key != null) owners.add(owner);
    }
    return SeedStatusOwners(owners, pendingOrUnreadable: incomplete);
  }

  @override
  Future<String?> activeKeyId(String owner) async {
    final key = await channel.invokeMethod<Object?>('syncStatusKeyId', {
      'owner': owner,
    });
    if (key != null && key is! String) {
      throw const FormatException('invalid key');
    }
    return key as String?;
  }

  @override
  Future<void> retryPending() async {
    final m = _map(
      await channel.invokeMethod<Object?>('syncRetryPending', {}),
      {'keyDeletesPending', 'purgesOwed', 'unreadableOwners'},
    );
    if (m.values.any((v) => v is! int || v < 0)) {
      throw const FormatException('invalid pending counts');
    }
  }

  @override
  Future<String> signStatus({
    required String owner,
    required String askedKeyId,
    required String challenge,
    required int expiresAt,
  }) async {
    final signature = await channel.invokeMethod<Object?>('syncStatusSign', {
      'owner': owner,
      'keyId': askedKeyId,
      'challenge': challenge,
      'expiresAt': expiresAt,
    });
    if (signature is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(signature)) {
      throw const FormatException('invalid signature');
    }
    return signature;
  }

  @override
  Future<String> applyStatus({
    required String owner,
    required String askedKeyId,
    required String state,
  }) async {
    final m = _map(
      await channel.invokeMethod<Object?>('syncStatusApply', {
        'owner': owner,
        'keyId': askedKeyId,
        'state': state,
      }),
      {'outcome'},
    );
    return switch (m['outcome']) {
      'kept' => 'KEPT',
      'purged' => 'PURGED',
      'noop' => 'NOOP',
      'pending' => 'PENDING',
      'unreadable' => 'UNREADABLE',
      _ => 'UNKNOWN',
    };
  }
}
