import 'dart:convert';

import 'package:flutter/services.dart';

/// Recovery metadata only. Never contains a TOTP seed, URI, label, assertion,
/// access token or passkey response. A session change must not delete it.
class ImportAttempt {
  const ImportAttempt({
    required this.ownerId,
    required this.deviceId,
    required this.nonce,
    required this.admissionId,
    required this.count,
    this.outcome = 'pending',
  });
  final String ownerId, deviceId, nonce, admissionId;
  final int count;
  final String outcome;
  ImportAttempt terminal(String result) => ImportAttempt(
    ownerId: ownerId,
    deviceId: deviceId,
    nonce: nonce,
    admissionId: admissionId,
    count: count,
    outcome: result,
  );
  Map<String, Object> get json => {
    'v': 2,
    'ownerId': ownerId,
    'deviceId': deviceId,
    'nonce': nonce,
    'admissionId': admissionId,
    'count': count,
    'outcome': outcome,
  };
  String encode() => jsonEncode(json);
  static ImportAttempt? decode(String raw) {
    try {
      if (utf8.encode(raw).length > 1024) return null;
      final v = jsonDecode(raw);
      if (v is! Map ||
          v.keys.toSet().difference({
            'v',
            'ownerId',
            'deviceId',
            'nonce',
            'admissionId',
            'count',
            'outcome',
          }).isNotEmpty ||
          v.length != 7 ||
          v['v'] != 2) {
        return null;
      }
      bool id(Object? s) =>
          s is String && RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(s);
      if (!{'pending', 'saved', 'fenced'}.contains(v['outcome'])) return null;
      if (!id(v['ownerId']) ||
          !id(v['deviceId']) ||
          v['nonce'] is! String ||
          !RegExp(r'^v2:[A-Za-z0-9_-]{22,61}$').hasMatch(v['nonce']) ||
          v['admissionId'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{22,64}$').hasMatch(v['admissionId']) ||
          v['count'] is! int ||
          v['count'] < 1 ||
          v['count'] > 50) {
        return null;
      }
      return ImportAttempt(
        ownerId: v['ownerId'],
        deviceId: v['deviceId'],
        nonce: v['nonce'],
        admissionId: v['admissionId'],
        count: v['count'],
        outcome: v['outcome'],
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'ImportAttempt(redacted)';
}

/// Native compare-and-set operations are atomic across service objects. An
/// unreadable record throws and blocks fresh work, it is never treated absent.
abstract interface class ImportJournal {
  Future<ImportAttempt?> read();
  Future<bool> claim(ImportAttempt value);
  Future<bool> replace(ImportAttempt expected, ImportAttempt terminal);
  Future<bool> clear(ImportAttempt expected);
}

class ChannelImportJournal implements ImportJournal {
  ChannelImportJournal([MethodChannel? channel])
    : channel = channel ?? const MethodChannel('app.otpanda/import-journal');
  final MethodChannel channel;
  @override
  Future<ImportAttempt?> read() async {
    final raw = await channel.invokeMethod<String>('read');
    if (raw == null) return null;
    final rec = ImportAttempt.decode(raw);
    if (rec == null) {
      throw const FormatException('Import recovery metadata unavailable');
    }
    return rec;
  }

  @override
  Future<bool> claim(ImportAttempt value) async =>
      await channel.invokeMethod<bool>('claim', {'record': value.encode()}) ==
      true;
  @override
  Future<bool> replace(ImportAttempt expected, ImportAttempt terminal) async =>
      await channel.invokeMethod<bool>('replace', {
        'expected': expected.encode(),
        'record': terminal.encode(),
      }) ==
      true;
  @override
  Future<bool> clear(ImportAttempt expected) async =>
      await channel.invokeMethod<bool>('clear', {
        'record': expected.encode(),
      }) ==
      true;
}

enum ImportRecovery { nothing, saved, fenced, unknown, foreign }

typedef ImportFencePost =
    Future<({int status, Map<String, dynamic>? body})> Function(
      Map<String, dynamic> body,
    );

/// Owns the durable barrier before a finish may leave the process. The server
/// fence/receipt, not elapsed time, is the only authority to clear this record.
class ImportRecoveryBarrier {
  ImportRecoveryBarrier({
    required this.journal,
    required this.ownerId,
    required this.deviceId,
    required this.current,
    required this.fence,
  });
  final ImportJournal journal;
  final String ownerId, deviceId;
  final Future<bool> Function() current;
  final ImportFencePost fence;
  Future<bool> beforeFinish(ImportAttempt rec) async {
    if (rec.outcome != 'pending' ||
        ImportAttempt.decode(rec.encode()) == null ||
        rec.ownerId != ownerId ||
        rec.deviceId != deviceId ||
        !await current()) {
      return false;
    }
    final old = await journal.read();
    // An existing attempt, including the same one, must be reconciled. Never
    // resend finish after restart or after a lost reply.
    if (old != null) return false;
    if (!await journal.claim(rec)) return false;
    return await current();
  }

  /// Even a clean finish reply must become durable before UI may say saved.
  /// Failure leaves pending and requires reconcile(), never another finish.
  Future<ImportRecovery> recordSaved(
    ImportAttempt rec,
    List<String> ids,
  ) async {
    try {
      if (!await current() ||
          rec.ownerId != ownerId ||
          rec.deviceId != deviceId ||
          ids.length != rec.count ||
          ids.toSet().length != ids.length ||
          ids.any((x) => x.isEmpty || x.length > 256)) {
        return ImportRecovery.unknown;
      }
      if (!await journal.replace(rec, rec.terminal('saved'))) {
        return ImportRecovery.unknown;
      }
      if (!await current()) return ImportRecovery.unknown;
      return ImportRecovery.saved;
    } catch (_) {
      return ImportRecovery.unknown;
    }
  }

  /// Called only after the terminal outcome has actually been presented by UI.
  /// A pending outcome cannot be acknowledged, nor a different session's record.
  Future<bool> acknowledge(ImportAttempt shown) async {
    if (shown.outcome == 'pending' ||
        shown.ownerId != ownerId ||
        shown.deviceId != deviceId ||
        !await current()) {
      return false;
    }
    return journal.clear(shown);
  }

  Future<ImportRecovery> reconcile() async {
    try {
      if (!await current()) return ImportRecovery.unknown;
      final rec = await journal.read();
      if (rec == null) return ImportRecovery.nothing;
      if (rec.ownerId != ownerId || rec.deviceId != deviceId) {
        return ImportRecovery.foreign;
      }
      if (rec.outcome == 'saved') return ImportRecovery.saved;
      if (rec.outcome == 'fenced') return ImportRecovery.fenced;
      // Only this verified owner/device boundary may reconcile the nonce.
      // It can never resend a finish or recover its seed-bearing payload.
      final r = await fence({
        'protocol': 2,
        'batchNonce': rec.nonce,
        'admissionId': rec.admissionId,
        'fence': true,
      });
      if (!await current() || r.status != 200) return ImportRecovery.unknown;
      final status = r.body?['status'];
      if (status != 'saved' && status != 'fenced') {
        return ImportRecovery.unknown;
      }
      if (status == 'saved') {
        final ids = r.body?['entryIds'];
        if (ids is! List ||
            ids.length != rec.count ||
            ids.any((x) => x is! String || x.isEmpty || x.length > 256) ||
            ids.toSet().length != ids.length) {
          return ImportRecovery.unknown;
        }
      }
      if (!await journal.replace(rec, rec.terminal(status))) {
        return ImportRecovery.unknown;
      }
      return status == 'saved' ? ImportRecovery.saved : ImportRecovery.fenced;
    } catch (_) {
      return ImportRecovery.unknown;
    }
  }
}
