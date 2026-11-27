import '../native/native_device_routes.dart' show DevicePost;
import '../native/native_passkey.dart';
import 'export_plan.dart';
import 'sealed_export_source.dart';

/// Bound to one freshly verified owner/device/generation. The caller retires
/// this transport on logout, owner/session change, lock or background. The
/// current fence is checked after every await and before releasing a proof.
class PasskeyExportTransport implements ExportTransport {
  PasskeyExportTransport({
    required this.post,
    required this.passkeys,
    required this.ownerId,
    required this.deviceId,
    required this.current,
    int Function()? nowMs,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  final DevicePost post;
  final PasskeyAssertionSource passkeys;
  final String ownerId, deviceId;
  final Future<bool> Function() current;
  final int Function() nowMs;
  final Set<Object> _attempts = {};
  Future<void> _check() async {
    if (!passkeys.available || !await current()) {
      throw const ExportAuthException(ExportAuthOutcome.cancelled);
    }
  }

  static final _id = RegExp(r'^[A-Za-z0-9._-]{1,256}$'),
      _version = RegExp(r'^[0-9a-f]{64}$');
  String? _text(Object? v) {
    if (v == null) return null;
    if (v is! String || v.length > 512) throw const ExportRejectedException();
    return v;
  }

  @override
  Future<ExportBegin> begin({
    required String ephemeralKey,
    List<String>? entryIds,
  }) async {
    await _check();
    if (ownerId.isEmpty || deviceId.isEmpty) {
      throw const ExportRejectedException();
    }
    final result = await post('/v1/manage/totp/export-begin', {
      'ephemeralKey': ephemeralKey,
      'entryIds': ?entryIds,
    });
    await _check();
    if (result.status != 200 || result.body == null) {
      throw const ExportRejectedException();
    }
    final body = result.body!,
        rows = body['entries'],
        missing = body['unavailable'];
    if (rows is! List ||
        rows.isEmpty ||
        rows.length > 200 ||
        missing is! List ||
        missing.length > 200 ||
        missing.any((x) => x is! String || !_id.hasMatch(x)) ||
        missing.toSet().length != missing.length) {
      throw const ExportRejectedException();
    }
    final generation = body['generation'];
    if (body['ownerId'] != ownerId ||
        body['deviceId'] != deviceId ||
        generation is! int ||
        generation < 0 ||
        generation > 9007199254740991) {
      throw const ExportRejectedException();
    }
    final entries = <ApprovedExportEntry>[];
    String? previous;
    for (final row in rows) {
      if (row is! Map ||
          row.length != 6 ||
          !{
            'entryId',
            'version',
            'label',
            'account',
            'issuer',
            'catalogId',
          }.every(row.containsKey)) {
        throw const ExportRejectedException();
      }
      final id = row['entryId'], version = row['version'];
      if (id is! String ||
          !_id.hasMatch(id) ||
          version is! String ||
          !_version.hasMatch(version) ||
          (previous != null && previous.compareTo(id) >= 0) ||
          missing.contains(id)) {
        throw const ExportRejectedException();
      }
      previous = id;
      entries.add(
        ApprovedExportEntry(
          entryId: id,
          version: version,
          label: _text(row['label']),
          account: _text(row['account']),
          issuer: _text(row['issuer']),
          catalogId: _text(row['catalogId']),
        ),
      );
    }
    if (entryIds != null &&
        (missing.isNotEmpty ||
            entries.length != entryIds.length ||
            !entries.every((e) => entryIds.contains(e.entryId)))) {
      throw const ExportRejectedException();
    }
    // Parse options before any prompt; retain only the original ceremony data.
    final request = passkeyRequestJson(body, nowMs: nowMs());
    final handle = _Handle(
      body['token'] as String,
      request,
      ephemeralKey,
      generation,
    );
    _attempts.add(handle);
    return ExportBegin(
      ownerId: ownerId,
      deviceId: deviceId,
      generation: generation,
      entries: List.unmodifiable(entries),
      unavailable: List.unmodifiable(missing.cast<String>()),
      handle: handle,
    );
  }

  @override
  Future<Map<String, Object?>> finish({
    required ExportBegin begin,
    required String ephemeralKey,
  }) async {
    final h = begin.handle;
    if (h is! _Handle ||
        !_attempts.remove(h) ||
        h.key != ephemeralKey ||
        begin.ownerId != ownerId ||
        begin.deviceId != deviceId ||
        begin.generation != h.generation) {
      throw const ExportRejectedException();
    }
    await _check();
    final assertion = await passkeys.get(h.request);
    await _check();
    if (assertion == null) {
      throw const ExportAuthException(ExportAuthOutcome.cancelled);
    }
    final response = passkeyAssertionBody(assertion);
    await _check();
    final result = await post('/v1/manage/totp/export-finish', {
      'ephemeralKey': ephemeralKey,
      'entries': [
        for (final e in begin.entries)
          {'entryId': e.entryId, 'version': e.version},
      ],
      'token': h.token,
      'response': response,
    });
    await _check();
    if (result.status == 409 && result.body?['error'] == 'changed') {
      throw const ExportChangedException();
    }
    if (result.status != 200 || result.body == null) {
      throw const ExportRejectedException();
    }
    return result.body!;
  }
}

class _Handle {
  const _Handle(this.token, this.request, this.key, this.generation);
  final int generation;
  final String token, request, key;
}
