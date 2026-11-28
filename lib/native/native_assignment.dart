import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'native_action_proof.dart';
import '../assignment_rule_contract.dart';
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
const assignmentPaths = {
  '/v1/manage/assignment/begin',
  '/v1/manage/assignment/finish',
  '/v1/manage/assignment/status',
};

bool assignmentRequestAllowed(String path, Map<String, dynamic> body) {
  final keys = body.keys.toList()..sort();
  final k = keys.join(',');
  final ok = switch (path) {
    '/v1/manage/assignment/begin' =>
      k == 'entryId,eventId,sourceId' || k == 'entryId,eventId,keyId,sourceId',
    '/v1/manage/assignment/finish' =>
      k == 'action,intentId' || k == 'action,intentId,signature,token',
    '/v1/manage/assignment/status' => k == 'intentId',
    _ => false,
  };
  return ok && utf8.encode(jsonEncode(body)).length <= 8192;
}

typedef AssignmentPost =
    Future<({int status, Map<String, dynamic>? body})> Function(
      String path,
      Map<String, dynamic> body,
    );

/// Who this phone is right now: the owner and, when the device key is enrolled
/// on the server, its key id. Read fresh for every assignment.
typedef AssignmentIdentity =
    Future<({String ownerId, String deviceId, String? keyId})?> Function();

const _open = <String>{'unknown', 'pending'};
const _review = <String>{'unknown', 'pending', 'submitting'};
final _tokenShape = RegExp(r'^otpda_[A-Za-z0-9_-]{55}$');

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

class NativeAssignmentDriver {
  NativeAssignmentDriver({
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
    if (!assignmentRequestAllowed(path, body)) {
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
          t.length != 3 ||
          t['sourceId'] is! String ||
          t['eventId'] is! String ||
          t['entryId'] is! String) {
        throw const FormatException();
      }
      final sourceId = t['sourceId'] as String;
      final eventId = t['eventId'] as String;
      final entryId = t['entryId'] as String;
      if ([
        sourceId,
        eventId,
        entryId,
      ].any((s) => s.isEmpty || s.length > 256)) {
        throw const FormatException();
      }
      final me = await identity();
      if (me == null) throw StateError('identity');
      final body = <String, dynamic>{
        'entryId': entryId,
        'eventId': eventId,
        'sourceId': sourceId,
        // A private target ignores the key; a shared one needs it.
        'keyId': ?me.keyId,
      };
      final r = await _send('/v1/manage/assignment/begin', body);
      final b = r.body;
      if (r.status != 200 || b == null) throw StateError('refused');
      final p = _check(b, me, sourceId, eventId, entryId);
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
    String sourceId,
    String eventId,
    String entryId,
  ) {
    final intentId = b['intentId'], action = b['action'];
    final exp = b['expiresAt'], s = b['summary'], proof = b['proofRequired'];
    if (intentId is! String ||
        intentId.isEmpty ||
        action is! String ||
        exp is! int ||
        exp <= _now() ||
        s is! Map<String, dynamic> ||
        proof is! bool ||
        s['entryId'] != entryId ||
        s['irreversible'] != true ||
        s['label'] is! String ||
        s['activeRecipients'] is! int ||
        s['automationRecipients'] is! int) {
      throw const FormatException();
    }
    if (utf8.encode(action).length > maxActionBytes) {
      throw const FormatException();
    }
    final Object? a = jsonDecode(action);
    if (a is! List) throw const FormatException();
    final rule = checkedAssignmentRule(a, s);
    final recipients = s['activeRecipients'] as int;
    final automations = s['automationRecipients'] as int;
    final summary = <String, dynamic>{
      'rule': ?rule,
      'operation': 'assign-code',
      'entryId': entryId,
      'label': s['label'],
      'accountName': s['accountName'],
      'serviceId': s['serviceId'],
      'activeRecipients': recipients,
      'automationRecipients': automations,
      'irreversible': true,
      'proofRequired': proof,
    };
    if (!proof) {
      // Owner-private: zero recipients and zero automation, v1 action, no
      // token and no challenge. Anything else is not trusted.
      if (b.containsKey('token') ||
          b.containsKey('challenge') ||
          b.containsKey('options') ||
          recipients != 0 ||
          automations != 0 ||
          !((a.length == 16 && a[1] == 1) || (a.length == 17 && a[1] == 3)) ||
          a[0] != 'otpanda-assignment' ||
          a[2] != intentId ||
          a[3] != me.ownerId ||
          a[4] != me.deviceId ||
          a[6] != sourceId ||
          a[7] != eventId ||
          a[8] != entryId ||
          a[13] != 0 ||
          a[14] != 0 ||
          a[15] != true) {
        throw const FormatException();
      }
      return (
        _Pending(
          intentId: intentId,
          action: action,
          token: null,
          challenge: null,
          prompt: null,
          expiresAt: exp,
        ),
        summary,
      );
    }
    // Shared: the enrolled device key signs a v2 action.
    final keyId = me.keyId;
    final token = b['token'];
    final c = parseDeviceChallenge({
      'token': token,
      'challenge': b['challenge'],
    }, 'step-up');
    if (keyId == null || token is! String || !_tokenShape.hasMatch(token)) {
      throw const FormatException();
    }
    if (c == null || c.ownerId != me.ownerId) throw const FormatException();
    final v = validateAssignmentActionV2(
      action,
      intentId: intentId,
      ownerId: me.ownerId,
      deviceId: me.deviceId,
      generation: c.generation,
      entryId: entryId,
      challengeActionDigest: c.actionDigest,
      challengePurpose: c.purpose,
      challengeKeyId: c.keyId,
      ownKeyId: keyId,
      challengeExpiresAt: c.expiresAt,
      nowMs: _now(),
    );
    if (v == null ||
        a[6] != sourceId ||
        a[7] != eventId ||
        v.recipients != recipients ||
        v.automations != automations ||
        v.entryLabel != s['label'] ||
        v.prompt.length > maxPromptTextLength) {
      throw const FormatException();
    }
    final promptText = rule?['status'] == 'already_saved_paused'
        ? 'Assign this code to ${v.entryLabel} (${v.accountName}), shared with ${v.recipients} people and ${v.automations} automations. The matching rule stays paused. Resume it separately.'
        : v.prompt;
    if (promptText.length > maxPromptTextLength) throw const FormatException();
    return (
      _Pending(
        intentId: intentId,
        action: action,
        token: token,
        challenge: c,
        prompt: promptText,
        expiresAt: exp,
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
      final r = await _send('/v1/manage/assignment/finish', {
        'action': p.action,
        'intentId': p.intentId,
        if (sig != null) 'signature': b64uNoPad(sig),
        if (sig != null) 'token': p.token!,
      });
      if (attempt != _generation) return _state;
      final st = r.status == 200 ? (r.body?['status']) : null;
      if (st == 'assigned' || st == 'not-assigned') {
        _state = st == 'assigned' && r.body?['rule']?['status'] == 'paused'
            ? 'assigned-paused'
            : st == 'assigned' && r.body?['rule']?['status'] == 'unavailable'
            ? 'assigned-no-rule'
            : st as String;
        _pending = null;
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
          r = await _send('/v1/manage/assignment/status', {
            'intentId': p.intentId,
          });
        } catch (_) {
          if (attempt == _generation) _state = 'unknown';
          return _state;
        }
        if (attempt != _generation) return _state;
        final st = r.status == 200 ? (r.body?['status']) : null;
        if (st == 'assigned' || st == 'not-assigned') {
          _state = st == 'assigned' && r.body?['rule']?['status'] == 'paused'
              ? 'assigned-paused'
              : st == 'assigned' && r.body?['rule']?['status'] == 'unavailable'
              ? 'assigned-no-rule'
              : st as String;
          _pending = null;
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

/// Identity for an assignment, read fresh each time: owner from the session
/// route, device from the live session, and the device key id only when this
/// phone's key is enrolled on the server (a failed read means no key, so only
/// an owner-private assignment can proceed).
AssignmentIdentity assignmentIdentity({
  required Future<Map<String, dynamic>?> Function() readSession,
  required String? Function() deviceId,
  required DeviceProofSource source,
  required DevicePost post,
}) => () async {
  final dev = deviceId();
  final o = (await readSession())?['ownerId'];
  if (dev == null || o is! String || o.isEmpty) return null;
  String? keyId;
  try {
    final spki = await source.publicKeyOrNull();
    if (spki != null) {
      final r = await DeviceStatusRoutes(post)
          .status(publicKeyDigest(spkiToJwk(spki)));
      if (r != null && r.status == ServerKeyStatus.enrolled) keyId = r.keyId;
    }
  } catch (_) {
    keyId = null;
  }
  return (ownerId: o, deviceId: dev, keyId: keyId);
};
