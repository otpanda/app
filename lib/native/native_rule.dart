import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'native_action_proof.dart';
import '../rule_action_contract.dart';
import 'native_assignment.dart' show AssignmentIdentity, AssignmentPost;
import 'native_device_proof.dart';
import 'native_device_routes.dart';

/// Native assignment ("assign this code to an entry"). Same states and strings
/// as the web AssignmentController, so the shared dialog works unchanged.
///
/// Rules (each one has a test):
///  - every server-built action is checked before any OS prompt;
///  - a shared target needs the enrolled device key (v2 action); a private one
///    needs no proof (v1 action, zero recipients and zero automation);
///  - a finish is sent once. A lost or odd answer is never "not done": the
///    driver reads status and never signs or finishes a second time;
///  - ceremony data stays in memory.

/// The only assignment paths a native client may POST, with their exact key
/// sets (the server rejects anything else with 400). Bodies are small JSON.
const rulePaths = {
  '/v1/manage/rule-intent/begin',
  '/v1/manage/rule-intent/finish',
  '/v1/manage/rule-intent/status',
};

bool ruleRequestAllowed(String path, Map<String, dynamic> body) {
  final keys = body.keys.toList()..sort();
  final k = keys.join(',');
  final ok = switch (path) {
    '/v1/manage/rule-intent/begin' =>
      k == 'contextId,entryId,operation,phrase' ||
          k == 'contextId,entryId,keyId,operation,phrase' ||
          k == 'entryId,operation,phrase,ruleId' ||
          k == 'entryId,keyId,operation,phrase,ruleId' ||
          k == 'entryId,operation,ruleId' ||
          k == 'entryId,keyId,operation,ruleId',
    '/v1/manage/rule-intent/finish' =>
      k == 'action,intentId' || k == 'action,intentId,signature,token',
    '/v1/manage/rule-intent/status' => k == 'intentId',
    _ => false,
  };
  return ok && utf8.encode(jsonEncode(body)).length <= 8192;
}

const _open = <String>{'unknown', 'pending'};
const _review = <String>{'unknown', 'pending', 'submitting'};

class _Pending {
  _Pending({
    required this.intentId,
    required this.action,
    required this.token,
    required this.challenge,
    required this.prompt,
    required this.expiresAt,
  });
  final String intentId, action;
  final String? token;
  final EnrollChallenge? challenge;
  final String? prompt;
  final int expiresAt;
}

class NativeRuleDriver {
  NativeRuleDriver({
    required this.post,
    required this.source,
    required this.identity,
    int Function()? now,
    Future<void> Function(Duration)? delay,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _delay = delay ?? ((d) => Future<void>.delayed(d));

  final AssignmentPost post;
  final DeviceProofSource source;
  final AssignmentIdentity identity;
  final int Function() _now;
  final Future<void> Function(Duration) _delay;

  String _state = 'idle';
  _Pending? _pending;
  bool _busy = false;
  int _generation = 0;

  String get state => _state;

  Future<({int status, Map<String, dynamic>? body})> _send(
    String path,
    Map<String, dynamic> body,
  ) {
    if (!ruleRequestAllowed(path, body)) {
      throw StateError('Assignment request not allowed');
    }
    return post(path, body);
  }

  /// Returns the summary JSON the shared dialog shows. Throws when anything
  /// does not check out (the dialog then shows "unavailable").
  Future<String> prepare(String target) async {
    if (_busy || _pending != null) {
      throw StateError('Reconcile or dismiss the current action first');
    }
    _busy = true;
    final attempt = _generation;
    try {
      final t = jsonDecode(target);
      if (t is! Map<String, dynamic> ||
          !['review', 'edit', 'resume'].contains(t['operation'])) {
        throw const FormatException();
      }
      final op = t['operation'],
          subject = op == 'review' ? 'contextId' : 'ruleId';
      if (t.keys.any(
            (k) => !{
              'operation',
              'entryId',
              subject,
              if (op != 'resume') 'phrase',
            }.contains(k),
          ) ||
          t['entryId'] is! String ||
          t[subject] is! String) {
        throw const FormatException();
      }
      final me = await identity();
      if (me == null) throw StateError('identity');
      final body = <String, dynamic>{
        'operation': op,
        'entryId': t['entryId'],
        subject: t[subject],
        if (op != 'resume') 'phrase': t['phrase'],
        'keyId': ?me.keyId,
      };
      final r = await _send('/v1/manage/rule-intent/begin', body);
      if (r.status != 200 || r.body == null) throw StateError('Rule refused');
      final p = _check(r.body!, me, t);
      if (attempt != _generation) throw StateError('changed');
      _pending = p.$1;
      _state = 'confirm';
      return jsonEncode(p.$2);
    } catch (_) {
      if (attempt == _generation) _state = 'unavailable';
      rethrow;
    } finally {
      if (attempt == _generation) _busy = false;
    }
  }

  /// All checks before any prompt. Returns the pending record and the summary.
  (_Pending, Map<String, dynamic>) _check(
    Map<String, dynamic> b,
    ({String ownerId, String deviceId, String? keyId}) me,
    Map<String, dynamic> target,
  ) {
    final summary = validateRuleAction(
      b,
      target,
      now: _now(),
      ownerId: me.ownerId,
      deviceId: me.deviceId,
      // Match the existing native action-proof 30-second clock allowance.
      // The server still enforces its exact two-minute intent expiry.
      maxAheadMs: maxProofLifetimeMs,
    );
    final action = b['action'] as String, a = jsonDecode(action) as List;
    if (b['proofRequired'] == false) {
      if (a[1] != 5 ||
          b.containsKey('token') ||
          b.containsKey('challenge') ||
          b.containsKey('options')) {
        throw const FormatException();
      }
      return (
        _Pending(
          intentId: b['intentId'],
          action: action,
          token: null,
          challenge: null,
          prompt: null,
          expiresAt: (b['expiresAt'] as int).clamp(0, _now() + 120000),
        ),
        summary,
      );
    }
    final c = parseDeviceChallenge({
      'token': b['token'],
      'challenge': b['challenge'],
    }, 'step-up');
    if (a[1] != 6 ||
        c == null ||
        me.keyId == null ||
        c.keyId != me.keyId ||
        c.ownerId != me.ownerId ||
        c.generation != a[5] ||
        c.actionDigest != hashText(action) ||
        c.expiresAt <= _now() ||
        c.expiresAt > _now() + maxProofLifetimeMs ||
        b.containsKey('options')) {
      throw const FormatException();
    }
    final prompt =
        '${summary['operation'] == 'rule-resume'
            ? 'Resume'
            : summary['operation'] == 'rule-edit'
            ? 'Change'
            : 'Save'} matching rule for ${summary['label']}. Account: ${summary['accountName'] ?? ''}. Connector: ${summary['sourceId']}. Sender: ${summary['sender']}. Match: ${summary['basis'] == 'template' ? 'template' : summary['phrase']}. Future sharing: ${summary['futureRecipients']} people, ${summary['futureAutomations']} automations.';
    if (prompt.length > maxPromptTextLength) throw const FormatException();
    return (
      _Pending(
        intentId: b['intentId'],
        action: action,
        token: b['token'],
        challenge: c,
        prompt: prompt,
        expiresAt: b['expiresAt'],
      ),
      summary,
    );
  }

  /// Only from a deliberate tap after the summary is shown.
  Future<String> confirm() async {
    final p = _pending;
    if (_busy || _state != 'confirm' || p == null) {
      throw StateError('Confirmation unavailable');
    }
    if (_now() >= p.expiresAt) {
      _state = 'expired';
      return _state;
    }
    _busy = true;
    _state = 'authenticating';
    final attempt = _generation;
    Uint8List? sig;
    final c = p.challenge;
    if (c != null) {
      try {
        final fields = DeviceProofFields(
          purpose: 'step-up',
          ownerId: c.ownerId,
          keyId: c.keyId,
          generation: c.generation,
          challenge: c.challenge,
          actionDigest: c.actionDigest,
          expiresAt: c.expiresAt,
        );
        fields.message;
        sig = await source.sign(fields, displayText: p.prompt);
      } catch (e) {
        if (attempt != _generation) return _state;
        _busy = false;
        _pending = null;
        _state =
            e is DeviceProofFailure &&
                e.kind == DeviceProofFailureKind.cancelled
            ? 'cancelled'
            : 'unavailable';
        return _state;
      }
      if (attempt != _generation) return _state;
      if (sig.length != 64) {
        _busy = false;
        _pending = null;
        _state = 'unavailable';
        return _state;
      }
    }
    // From here a write may have happened: never sign or finish again.
    _state = 'submitting';
    try {
      final r = await _send('/v1/manage/rule-intent/finish', {
        'action': p.action,
        'intentId': p.intentId,
        if (sig != null) 'signature': b64uNoPad(sig),
        if (sig != null) 'token': p.token!,
      });
      if (attempt != _generation) return _state;
      final st = r.status == 200 ? (r.body?['status']) : null;
      if (st == 'applied' || st == 'not-applied') {
        _state = st == 'applied' ? _applied(r.body) : 'not-applied';
        if (_state != 'unknown') _pending = null;
        return _state;
      }
    } catch (_) {
      if (attempt != _generation) return _state;
    } finally {
      if (attempt == _generation) _busy = false;
    }
    _state = 'unknown';
    return reconcile();
  }

  Future<String> reconcile() async {
    final p = _pending;
    if (_busy || p == null || !_open.contains(_state)) {
      return _state;
    }
    _busy = true;
    final attempt = _generation;
    try {
      for (final wait in const [0, 500, 1500, 3000]) {
        if (wait > 0) await _delay(Duration(milliseconds: wait));
        if (attempt != _generation) return _state;
        ({int status, Map<String, dynamic>? body}) r;
        try {
          r = await _send('/v1/manage/rule-intent/status', {
            'intentId': p.intentId,
          });
        } catch (_) {
          if (attempt == _generation) _state = 'unknown';
          return _state;
        }
        if (attempt != _generation) return _state;
        final st = r.status == 200 ? (r.body?['status']) : null;
        if (st == 'applied' || st == 'not-applied') {
          _state = st == 'applied' ? _applied(r.body) : 'not-applied';
          if (_state != 'unknown') _pending = null;
          return _state;
        }
        if (st != 'pending') {
          _state = 'unknown';
          return _state;
        }
        _state = 'pending';
      }
      return _state;
    } finally {
      if (attempt == _generation) _busy = false;
    }
  }

  String _applied(Map<String, dynamic>? body) {
    final r = body?['rule'];
    if (r is! Map ||
        ![
          'saved',
          'exists',
          'updated',
          'resumed',
          'paused',
          'unavailable',
        ].contains(r['status'])) {
      return 'unknown';
    }
    return r['status'] == 'paused'
        ? 'paused'
        : r['status'] == 'unavailable'
        ? 'applied-unavailable'
        : 'applied';
  }

  /// Sign-out or disposal: late results are dropped. A sent write is not undone.
  void clear() {
    _generation++;
    _pending = null;
    _busy = false;
    _state = 'idle';
  }

  void dismiss() {
    if (_busy || _review.contains(_state)) {
      throw StateError('Outcome still needs review');
    }
    _pending = null;
    _state = 'idle';
  }
}
