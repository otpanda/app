import 'package:flutter/services.dart';

import 'seed_install_id.dart';

/// Inactive bridge to the install-only noBackup store. Never uses session prefs.
final class SeedInstallIdChannelStore implements SeedInstallIdStore {
  SeedInstallIdChannelStore(this.channel);
  final MethodChannel channel;

  Map<Object?, Object?> _map(Object? value, Set<String> keys) {
    if (value is! Map ||
        value.length != keys.length ||
        !keys.every(value.containsKey)) {
      throw const FormatException('invalid install id reply');
    }
    return value;
  }

  @override
  Future<String?> read() async {
    final m = _map(
      await channel.invokeMethod<Object?>('syncInstallIdGet', {}),
      {'installId'},
    );
    final id = m['installId'];
    if (id != null && id is! String) {
      throw const FormatException('invalid install id');
    }
    return id as String?;
  }

  @override
  Future<String> createIfAbsent(String candidate) async {
    final m = _map(
      await channel.invokeMethod<Object?>('syncInstallIdEnsure', {
        'installId': candidate,
      }),
      {'installId', 'created'},
    );
    if (m['installId'] is! String || m['created'] is! bool) {
      throw const FormatException('invalid install id creation reply');
    }
    return m['installId'] as String;
  }
}
