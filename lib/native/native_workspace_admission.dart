import 'package:flutter/services.dart';

final class NativeWorkspaceScope {
  const NativeWorkspaceScope(
    this.owner,
    this.install,
    this.epoch,
    this.namespace,
    this.path,
  );
  final String owner, install, namespace, path;
  final int epoch;
  static NativeWorkspaceScope parse(Object? raw) {
    if (raw is! Map ||
        raw.length != 5 ||
        raw['owner'] is! String ||
        raw['install'] is! String ||
        raw['epoch'] is! int ||
        raw['namespace'] is! String ||
        raw['path'] is! String) {
      throw const FormatException('Invalid workspace scope');
    }
    final s = NativeWorkspaceScope(
      raw['owner'],
      raw['install'],
      raw['epoch'],
      raw['namespace'],
      raw['path'],
    );
    if (s.owner.isEmpty ||
        !RegExp(r'^[A-Za-z0-9_-]{22,64}$').hasMatch(s.install) ||
        s.epoch < 0 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(s.namespace) ||
        !s.path.startsWith('/') ||
        s.path.contains('/../')) {
      throw const FormatException('Invalid workspace scope');
    }
    return s;
  }

  bool same(NativeWorkspaceScope other) =>
      owner == other.owner &&
      install == other.install &&
      epoch == other.epoch &&
      namespace == other.namespace &&
      path == other.path;
}

/// No bearer or account authority is inferred by this adapter. Admit is called
/// only after an authenticated current-owner read by the native composition.
class NativeWorkspaceAdmission {
  NativeWorkspaceAdmission({MethodChannel? channel})
    : channel =
          channel ?? const MethodChannel('app.otpanda/workspace-admission');
  final MethodChannel channel;
  Future<NativeWorkspaceScope?> discover() async {
    final raw = await channel.invokeMapMethod<Object?, Object?>('discover', {});
    if (raw == null || raw.length != 4 || raw['createAllowed'] != false) {
      throw const FormatException('Invalid discovery');
    }
    if (raw['status'] == 'absent' &&
        raw['scope'] == null &&
        raw['reason'] == null) {
      return null;
    }
    if (raw['status'] != 'ready' || raw['reason'] != null) {
      throw StateError('Local workspace unavailable');
    }
    return NativeWorkspaceScope.parse(raw['scope']);
  }

  Future<({NativeWorkspaceScope scope, bool create})> admit(
    String owner,
    int epoch,
  ) async {
    final raw = await channel.invokeMapMethod<Object?, Object?>('admit', {
      'owner': owner,
      'epoch': epoch,
    });
    if (raw == null || raw.length != 2 || raw['createAllowed'] is! bool) {
      throw const FormatException('Invalid admission');
    }
    final scope = NativeWorkspaceScope.parse(raw['scope']);
    if (scope.owner != owner || scope.epoch != epoch) {
      throw StateError('Admission mismatch');
    }
    return (scope: scope, create: raw['createAllowed'] as bool);
  }

  Future<void> confirm(NativeWorkspaceScope scope) async {
    final raw = await channel.invokeMapMethod<Object?, Object?>('confirm', {
      'owner': scope.owner,
      'epoch': scope.epoch,
    });
    if (raw == null ||
        raw.length != 1 ||
        !scope.same(NativeWorkspaceScope.parse(raw['scope']))) {
      throw StateError('Workspace confirmation mismatch');
    }
  }

  Future<void> invalidate(String owner) async {
    final raw = await channel.invokeMapMethod<Object?, Object?>('invalidate', {
      'owner': owner,
    });
    if (raw == null || raw.length != 1 || raw['invalidated'] is! bool) {
      throw StateError('Workspace invalidation unavailable');
    }
  }
}
