import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../native/native_device_routes.dart' show DevicePost;
import '../native/native_passkey.dart';
import '../offline_totp/otp_account.dart';
import '../offline_totp/otpauth_uri.dart';
import 'import_review.dart';

/// One whole selection, one passkey confirmation, one atomic server batch.
/// A nonce remains attached to an unknown attempt for this instance's lifetime.
/// Nothing auto-retries, chunks, replaces an entry or invents a new nonce after
/// an unknown outcome. A caller recovering after process death must re-read the
/// accounts before starting a new import, not silently replay a selection.
class BatchImportSaver implements ImportSaver {
  BatchImportSaver({
    required this.post,
    required this.passkeys,
    required this.current,
    int Function()? nowMs,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  final DevicePost post;
  final PasskeyAssertionSource passkeys;
  final Future<bool> Function() current;
  final int Function() nowMs;
  String? _nonce, _payload;
  bool _busy = false, _unknown = false;
  @override
  bool get atomic => true;

  static String _newNonce() =>
      base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256)))
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

  @override
  Future<ImportSaveOutcome> save(List<OtpAccount> accounts) async {
    if (_busy) return ImportSaveOutcome.notSaved;
    final outcome = await _save(accounts);
    if (!_unknown &&
        (outcome == ImportSaveOutcome.saved ||
            outcome == ImportSaveOutcome.notSaved ||
            outcome == ImportSaveOutcome.cancelled)) {
      _payload = null;
      _nonce = null;
    }
    return outcome;
  }

  Future<ImportSaveOutcome> _save(List<OtpAccount> accounts) async {
    if (_busy || accounts.isEmpty || accounts.length > 50) {
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
    final payload = sha256.convert(utf8.encode(jsonEncode(items))).toString();
    if (_payload != null && _payload != payload) {
      return ImportSaveOutcome.unknown;
    }
    _busy = true;
    var finishStarted = false;
    try {
      if (!await current() || !passkeys.available) {
        return _unknown
            ? ImportSaveOutcome.unknown
            : ImportSaveOutcome.notSaved;
      }
      _payload = payload;
      _nonce ??= _newNonce();
      final body = {'batchNonce': _nonce, 'items': items};
      if (utf8.encode(jsonEncode(body)).length > 65000) {
        return ImportSaveOutcome.notSaved;
      }
      final begin = await post('/v1/manage/totp/batch-begin', body);
      if (!await current()) {
        return _unknown
            ? ImportSaveOutcome.unknown
            : ImportSaveOutcome.cancelled;
      }
      if (begin.status != 200 || begin.body == null) {
        return _unknown
            ? ImportSaveOutcome.unknown
            : ImportSaveOutcome.notSaved;
      }
      if (begin.body!['status'] == 'saved') {
        if (_ids(begin.body, accounts.length) == null) {
          return ImportSaveOutcome.unknown;
        }
        _unknown = false;
        return ImportSaveOutcome.saved;
      }
      final request = passkeyRequestJson(begin.body!, nowMs: nowMs());
      final assertion = await passkeys.get(request);
      if (assertion == null || !await current()) {
        return _unknown
            ? ImportSaveOutcome.unknown
            : ImportSaveOutcome.cancelled;
      }
      final finish = {
        ...body,
        'token': begin.body!['token'],
        'response': passkeyAssertionBody(assertion),
      };
      if (utf8.encode(jsonEncode(finish)).length > 65536) {
        return ImportSaveOutcome.notSaved;
      }
      finishStarted = true;
      _unknown = true;
      final done = await post('/v1/manage/totp/batch-finish', finish);
      if ((done.status == 200 || done.status == 201) &&
          _ids(done.body, accounts.length) != null) {
        _unknown = false;
        return ImportSaveOutcome.saved;
      }
      // A consumed ceremony can coexist with a committed batch whose response
      // was lost. Outcome read is non-mutating; never send finish twice here.
      if (!await current()) return ImportSaveOutcome.unknown;
      final outcome = await post('/v1/manage/totp/batch-outcome', {
        'batchNonce': _nonce,
      });
      if (outcome.status == 200 &&
          outcome.body?['status'] == 'saved' &&
          _ids(outcome.body, accounts.length) != null) {
        _unknown = false;
        return ImportSaveOutcome.saved;
      }
      if (outcome.status == 200 &&
          outcome.body?['status'] == 'none' &&
          [400, 401, 403, 409, 413].contains(done.status)) {
        _unknown = false;
        return ImportSaveOutcome.notSaved;
      }
      return ImportSaveOutcome.unknown;
    } catch (_) {
      return finishStarted || _unknown
          ? ImportSaveOutcome.unknown
          : ImportSaveOutcome.notSaved;
    } finally {
      _busy = false;
    }
  }
}
