import 'dart:convert';
import 'dart:math';

import '../import_recovery_journal.dart';

import '../native/native_device_routes.dart' show DevicePost;
import '../native/native_passkey.dart';
import '../offline_totp/otp_account.dart';
import '../offline_totp/otpauth_uri.dart';
import 'import_review.dart';

/// One whole selection, one passkey confirmation, one atomic server batch.
/// A durable admission journal blocks resend after process death.
/// Nothing auto-retries, chunks, replaces an entry or invents a new nonce after
/// an unknown outcome. Restart recovery fences the exact admission, never
/// replays the seed-bearing selection.
class BatchImportSaver
    implements RecoverableImportSaver, ImportAcknowledgementSource {
  BatchImportSaver({
    required this.post,
    required this.passkeys,
    required this.current,
    required this.recovery,
    int Function()? nowMs,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  final DevicePost post;
  final PasskeyAssertionSource passkeys;
  final Future<bool> Function() current;
  final int Function() nowMs;
  final ImportRecoveryBarrier recovery;
  ImportAttempt? _attempt;
  ImportAttempt? _shown;
  bool _busy = false;
  @override
  bool get atomic => true;

  static String _newNonce() =>
      'v2:${base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256)))}'
          .replaceAll('=', '');
  List<String>? _ids(Map<String, dynamic>? body, int count) {
    final raw = body?['entryIds'];
    if (raw is! List ||
        raw.length != count ||
        raw.any((x) => x is! String || x.isEmpty || x.length > 256) ||
        raw.toSet().length != raw.length) {
      return null;
    }
    return raw.cast<String>();
  }

  ImportSaveOutcome _mapped(ImportRecovery r) => switch (r) {
    ImportRecovery.saved => ImportSaveOutcome.saved,
    ImportRecovery.fenced => ImportSaveOutcome.notSaved,
    _ => ImportSaveOutcome.unknown,
  };
  @override
  Future<ImportSaveOutcome> reconcile() async {
    if (_busy) return ImportSaveOutcome.unknown;
    _busy = true;
    try {
      return await _reconcile();
    } finally {
      _busy = false;
    }
  }

  Future<ImportSaveOutcome> _reconcile() async {
    final attempt = _attempt;
    if (attempt == null) return ImportSaveOutcome.unknown;
    final rec = await recovery.journal.read();
    if (rec == null || !_sameAttempt(rec, attempt)) {
      return ImportSaveOutcome.unknown;
    }
    final result = _mapped(await recovery.reconcile());
    return _present(result);
  }

  bool _sameAttempt(ImportAttempt a, ImportAttempt b) =>
      a.ownerId == b.ownerId &&
      a.deviceId == b.deviceId &&
      a.nonce == b.nonce &&
      a.admissionId == b.admissionId &&
      a.count == b.count;
  Future<ImportSaveOutcome> _present(ImportSaveOutcome result) async {
    final rec = await recovery.journal.read(), attempt = _attempt;
    if (rec != null &&
        attempt != null &&
        _sameAttempt(rec, attempt) &&
        ((result == ImportSaveOutcome.saved && rec.outcome == 'saved') ||
            (result == ImportSaveOutcome.notSaved &&
                rec.outcome == 'fenced'))) {
      _shown = rec;
    }
    return result;
  }

  @override
  Future<bool> Function() captureShownAcknowledgement() {
    final shown = _shown;
    return () async {
      if (_busy) return false;
      if (shown == null) return true;
      _busy = true;
      try {
        final cleared = await recovery.acknowledge(shown);
        if (cleared && _shown?.encode() == shown.encode()) _shown = null;
        return cleared;
      } finally {
        _busy = false;
      }
    };
  }

  @override
  Future<bool> acknowledgeShown() => captureShownAcknowledgement()();

  @override
  Future<ImportSaveOutcome> save(List<OtpAccount> accounts) async {
    if (_busy) return ImportSaveOutcome.blocked;
    _busy = true;
    var finishStarted = false;
    try {
      final prior = await recovery.journal.read();
      if (prior != null) return ImportSaveOutcome.blocked;
      _attempt = null;
      _shown = null;
      if (accounts.isEmpty || accounts.length > 50) {
        return ImportSaveOutcome.notSaved;
      }
      final items = [
        for (final a in accounts)
          {
            'label': a.issuer ?? a.accountName,
            'account': a.accountName,
            'secret': encodeOtpauthUri(a),
          },
      ];
      if (items.any(
        (i) =>
            i['label']!.trim().isEmpty ||
            i['label']!.length > 120 ||
            i['account']!.length > 120 ||
            i['secret']!.length > 2048,
      )) {
        return ImportSaveOutcome.notSaved;
      }
      if (!await current() || !passkeys.available) {
        return ImportSaveOutcome.notSaved;
      }
      final nonce = _newNonce();
      final body = {'protocol': 2, 'batchNonce': nonce, 'items': items};
      if (utf8.encode(jsonEncode(body)).length > 65000) {
        return ImportSaveOutcome.notSaved;
      }
      final begin = await post('/v1/manage/totp/batch-begin', body);
      if (!await current()) {
        return ImportSaveOutcome.cancelled;
      }
      if (begin.status == 429 && begin.body?['error'] == 'import_capacity') {
        return ImportSaveOutcome.capacity;
      }
      if (begin.status != 200 || begin.body == null) {
        return ImportSaveOutcome.notSaved;
      }
      final admissionId = begin.body!['admissionId'];
      if (begin.body!['protocol'] != 2 ||
          admissionId is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{22,64}$').hasMatch(admissionId)) {
        return ImportSaveOutcome.notSaved;
      }
      _attempt = ImportAttempt(
        ownerId: recovery.ownerId,
        deviceId: recovery.deviceId,
        nonce: nonce,
        admissionId: admissionId,
        count: accounts.length,
      );
      if (begin.body!['status'] == 'saved') {
        final ids = _ids(begin.body, accounts.length);
        if (ids == null) return ImportSaveOutcome.unknown;
        if (!await recovery.beforeFinish(_attempt!)) {
          return ImportSaveOutcome.unknown;
        }
        final terminal = await recovery.recordSaved(_attempt!, ids);
        return terminal == ImportRecovery.saved
            ? await _present(ImportSaveOutcome.saved)
            : await _reconcile();
      }
      final request = passkeyRequestJson(begin.body!, nowMs: nowMs());
      final assertion = await passkeys.get(request);
      if (assertion == null || !await current()) {
        return ImportSaveOutcome.cancelled;
      }
      final finish = {
        ...body,
        'admissionId': admissionId,
        'token': begin.body!['token'],
        'response': passkeyAssertionBody(assertion),
      };
      if (utf8.encode(jsonEncode(finish)).length > 65536) {
        return ImportSaveOutcome.notSaved;
      }
      if (!await recovery.beforeFinish(_attempt!)) {
        return ImportSaveOutcome.unknown;
      }
      finishStarted = true;
      final done = await post('/v1/manage/totp/batch-finish', finish);
      if ((done.status == 200 || done.status == 201) &&
          _ids(done.body, accounts.length) != null) {
        final durable = await recovery.recordSaved(
          _attempt!,
          _ids(done.body, accounts.length)!,
        );
        return durable == ImportRecovery.saved
            ? await _present(ImportSaveOutcome.saved)
            : await _reconcile();
      }
      // A consumed ceremony or a lost reply can coexist with a committed
      // batch, and a plain read of "none" cannot exclude a late commit. Only a
      // server fence is terminal. No finish is ever sent twice.
      return await _reconcile();
    } catch (_) {
      return finishStarted ? await _reconcile() : ImportSaveOutcome.blocked;
    } finally {
      _busy = false;
    }
  }
}
