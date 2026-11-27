import 'dart:convert';
import 'dart:typed_data';

import 'import_outcome.dart';
import 'otp_account.dart';

/// Google Authenticator "otpauth-migration://offline?data=BASE64_PROTOBUF"
/// transfer format (MigrationPayload). Accounts only; TOTP only.
///
/// The format cannot carry a period or 7 digits (6 and 8 only). Import therefore maps to the
/// standard 30 s period, and export REFUSES accounts it cannot represent
/// exactly instead of silently changing them. HOTP and MD5 entries are refused.
const maxMigrationUriLength = 16384, maxAccountsPerBatch = 50;

/// OTPanda extension on OtpParameters: protobuf field 15, varint, the TOTP
/// period in seconds (1..86400). Google ignores unknown fields and shows 30 s
/// (user-tested with a synthetic QR on Nov 26: period 60 in field 15). Written
/// only when the period is not 30, and only when the caller opts in.
const otpandaPeriodField = 15;

class MigrationBatch {
  MigrationBatch(
    this.accounts,
    this.version,
    this.batchSize,
    this.batchIndex,
    this.batchId, [
    this.skipped = const [],
  ]);
  final List<OtpAccount> accounts;

  /// Entries refused individually (only when parsed with skipUnsupported).
  final List<SkippedEntry> skipped;
  final int version, batchSize, batchIndex, batchId;
  @override
  String toString() => 'MigrationBatch(redacted)';
}

/// [skipUnsupported] keeps going past entries that are HOTP, MD5 or otherwise
/// unsupported and lists them in [MigrationBatch.skipped]; a malformed
/// container is still refused as a whole.
MigrationBatch parseMigrationUri(String input, {bool skipUnsupported = false}) {
  try {
    if (input.length > maxMigrationUriLength ||
        RegExp(r'[\s\u0000-\u001f\u007f]').hasMatch(input)) {
      throw const OtpFormatException(OtpFormatError.malformed);
    }
    final m = RegExp(r'^otpauth-migration://offline\?data=([^&#]+)$')
        .firstMatch(input);
    if (m == null) throw const OtpFormatException(OtpFormatError.malformed);
    final raw = Uri.decodeQueryComponent(m.group(1)!);
    final bytes = base64.decode(base64.normalize(raw));
    return _decodePayload(bytes, skipUnsupported);
  } on OtpFormatException {
    rethrow;
  } catch (_) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
}

/// Combine batches scanned in any order. All must share one batch id, size and
/// version, with every index 0..size-1 exactly once. Anything else is refused.
List<OtpAccount> assembleBatches(List<MigrationBatch> batches) {
  if (batches.isEmpty) {
    throw const OtpFormatException(OtpFormatError.incompleteBatch);
  }
  final first = batches.first;
  final size = first.batchSize < 1 ? 1 : first.batchSize;
  if (batches.length != size) {
    throw const OtpFormatException(OtpFormatError.incompleteBatch);
  }
  final seen = <int>{};
  for (final b in batches) {
    if (b.batchId != first.batchId ||
        b.version != first.version ||
        (b.batchSize < 1 ? 1 : b.batchSize) != size ||
        b.batchIndex < 0 ||
        b.batchIndex >= size ||
        !seen.add(b.batchIndex)) {
      throw const OtpFormatException(OtpFormatError.incompleteBatch);
    }
  }
  final ordered = [...batches]
    ..sort((a, b) => a.batchIndex.compareTo(b.batchIndex));
  return [for (final b in ordered) ...b.accounts];
}

/// Like [assembleBatches] but keeps the per-entry skips (in batch order).
ImportOutcome assembleBatchesWithSkipped(List<MigrationBatch> batches) {
  final accounts = assembleBatches(batches);
  final ordered = [...batches]
    ..sort((a, b) => a.batchIndex.compareTo(b.batchIndex));
  var offset = 0;
  final skipped = <SkippedEntry>[];
  for (final b in ordered) {
    for (final s in b.skipped) {
      skipped.add(
        SkippedEntry(
          offset + s.position,
          s.error,
          issuer: s.issuer,
          accountName: s.accountName,
        ),
      );
    }
    offset += b.accounts.length + b.skipped.length;
  }
  return ImportOutcome(accounts, skipped);
}

/// The single rule for what the Google migration format can carry exactly: a
/// 30 s period and 6 or 8 digits. Used by both the export planner and the
/// encoder, so they cannot disagree.
bool isMigrationRepresentable(OtpAccount a) =>
    a.period == 30 && (a.digits == 6 || a.digits == 8);

/// Split accounts for a Google migration export: [google] can be carried
/// exactly; [otpauthOnly] cannot (not 30 s with 6 or 8 digits) and must go out as Key URIs
/// instead. Nothing is dropped or changed.
({List<OtpAccount> google, List<OtpAccount> otpauthOnly}) planMigrationExport(
  List<OtpAccount> accounts, {
  bool Function(OtpAccount) representable = isMigrationRepresentable,
}) {
  final google = <OtpAccount>[], other = <OtpAccount>[];
  for (final a in accounts) {
    (representable(a) ? google : other).add(a);
  }
  return (google: google, otpauthOnly: other);
}

/// Encode accounts as one or more migration URIs (contains secrets: call only
/// behind strong re-authentication). [batchId] must be fresh per export.
List<String> encodeMigrationUris(
  List<OtpAccount> accounts, {
  required int batchId,
  int perBatch = 10,
  bool periodExtension = false,
}) {
  if (accounts.isEmpty ||
      perBatch < 1 ||
      perBatch > maxAccountsPerBatch ||
      batchId < 0 ||
      batchId > 0x7fffffff) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  for (final a in accounts) {
    final ok = periodExtension
        ? (a.digits == 6 || a.digits == 8) && a.period >= 1 && a.period <= 86400
        : isMigrationRepresentable(a);
    if (!ok) {
      throw const OtpFormatException(OtpFormatError.notRepresentable);
    }
  }
  var chunks = <List<OtpAccount>>[
    for (var i = 0; i < accounts.length; i += perBatch)
      accounts.sublist(
        i,
        i + perBatch > accounts.length ? accounts.length : i + perBatch,
      ),
  ];
  // Never emit what our own decoder would refuse: split any chunk whose URI
  // exceeds maxMigrationUriLength and re-encode with the new batch count.
  for (;;) {
    final uris = [
      for (var i = 0; i < chunks.length; i++)
        'otpauth-migration://offline?data=${Uri.encodeQueryComponent(base64.encode(_encodePayload(chunks[i], chunks.length, i, batchId, periodExtension)))}',
    ];
    final big = [
      for (var i = 0; i < uris.length; i++)
        if (uris[i].length > maxMigrationUriLength) i,
    ];
    if (big.isEmpty) return uris;
    final next = <List<OtpAccount>>[];
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      if (!big.contains(i)) {
        next.add(c);
      } else if (c.length == 1) {
        throw const OtpFormatException(OtpFormatError.tooLarge);
      } else {
        final h = c.length ~/ 2;
        next
          ..add(c.sublist(0, h))
          ..add(c.sublist(h));
      }
    }
    chunks = next;
  }
}

// ---- minimal protobuf ----
class _Reader {
  _Reader(this.b);
  final Uint8List b;
  int i = 0;
  bool get done => i >= b.length;
  // Exact 64-bit varint via BigInt, so the Dart VM and compiled JS agree on
  // every byte string. At most 10 bytes, 10th byte 0 or 1.
  BigInt _raw() {
    var v = BigInt.zero;
    for (var n = 0; n < 10; n++) {
      if (i >= b.length) {
        throw const OtpFormatException(OtpFormatError.malformed);
      }
      final x = b[i++];
      if (n == 9 && x > 1) {
        throw const OtpFormatException(OtpFormatError.malformed);
      }
      v |= BigInt.from(x & 0x7f) << (7 * n);
      if (x & 0x80 == 0) return v;
    }
    throw const OtpFormatException(OtpFormatError.malformed);
  }

  static final _two32 = BigInt.one << 32, _two64 = BigInt.one << 64;

  /// Tags, lengths and enum values: must fit in 32 bits unsigned.
  int u32() {
    final v = _raw();
    if (v >= _two32) throw const OtpFormatException(OtpFormatError.malformed);
    return v.toInt();
  }

  /// int32 fields: plain, or a negative value sign-extended to 64 bits (the
  /// 10-byte form). Returned as the unsigned 32-bit pattern.
  int i32() {
    final v = _raw();
    if (v < _two32) return v.toInt();
    if (v >= _two64 - (BigInt.one << 31)) {
      return (v & (_two32 - BigInt.one)).toInt();
    }
    throw const OtpFormatException(OtpFormatError.malformed);
  }

  void skipVarint() => _raw();

  Uint8List bytes() {
    final n = u32();
    if (n < 0 || i + n > b.length) {
      throw const OtpFormatException(OtpFormatError.malformed);
    }
    final out = Uint8List.sublistView(b, i, i + n);
    i += n;
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        skipVarint();
      case 1:
        _fixed(8);
      case 2:
        bytes();
      case 5:
        _fixed(4);
      default:
        throw const OtpFormatException(OtpFormatError.malformed);
    }
  }

  void _fixed(int n) {
    if (i + n > b.length) {
      throw const OtpFormatException(OtpFormatError.malformed);
    }
    i += n;
  }
}

// A refused entry whose own content is unsupported can be skipped; a decoding
// error (truncated bytes, bad UTF-8, duplicate fields) means the payload itself
// is untrustworthy, so it is never skipped.
const _skippable = {
  OtpFormatError.unsupportedType,
  OtpFormatError.unsupportedAlgorithm,
  OtpFormatError.unsupportedDigits,
  OtpFormatError.badSecret,
};

MigrationBatch _decodePayload(Uint8List data, bool skipUnsupported) {
  final r = _Reader(data);
  final accounts = <OtpAccount>[];
  final skipped = <SkippedEntry>[];
  var entries = 0;
  var version = 0, size = 0, index = 0, id = 0;
  final seen = <int>{};
  while (!r.done) {
    final tag = r.u32(), field = tag ~/ 8, wire = tag % 8;
    if (field == 1 && wire == 2) {
      if (++entries > maxAccountsPerBatch) {
        throw const OtpFormatException(OtpFormatError.tooLarge);
      }
      final entry = r.bytes();
      String? seenIssuer, seenName;
      try {
        accounts.add(
          _decodeParams(
            entry,
            onLabels: (i, n) {
              seenIssuer = displayableLabel(i);
              seenName = displayableLabel(n);
            },
          ),
        );
      } on OtpFormatException catch (e) {
        if (!skipUnsupported || !_skippable.contains(e.error)) rethrow;
        skipped.add(
          SkippedEntry(
            entries,
            e.error,
            issuer: seenIssuer,
            accountName: seenName,
          ),
        );
      }
    } else if (wire == 0 && field >= 2 && field <= 5) {
      if (!seen.add(field)) {
        throw const OtpFormatException(OtpFormatError.malformed);
      }
      final v = r.i32();
      switch (field) {
        case 2:
          version = v;
        case 3:
          size = v;
        case 4:
          index = v;
        case 5:
          id = v % 4294967296;
      }
    } else {
      r.skip(wire);
    }
  }
  if (version != 1) throw const OtpFormatException(OtpFormatError.malformed);
  if (accounts.isEmpty && skipped.isEmpty) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  return MigrationBatch(accounts, version, size, index, id, skipped);
}

OtpAccount _decodeParams(
  Uint8List data, {
  void Function(String? issuer, String? name)? onLabels,
}) {
  final r = _Reader(data);
  Uint8List? secret;
  String? name, issuer;
  var algo = 0, digits = 0, type = 0;
  int? extPeriod;
  final seen = <int>{};
  while (!r.done) {
    final tag = r.u32(), field = tag ~/ 8, wire = tag % 8;
    if ((field >= 1 && field <= 6 || field == otpandaPeriodField) &&
        !seen.add(field)) {
      throw const OtpFormatException(OtpFormatError.malformed);
    }
    if (field == 1 && wire == 2) {
      secret = r.bytes();
    } else if (field == 2 && wire == 2) {
      name = _utf8(r.bytes());
    } else if (field == 3 && wire == 2) {
      issuer = _utf8(r.bytes());
    } else if (field == 4 && wire == 0) {
      algo = r.u32();
    } else if (field == 5 && wire == 0) {
      digits = r.u32();
    } else if (field == 6 && wire == 0) {
      type = r.u32();
    } else if (field == otpandaPeriodField) {
      // Our own extension: a wrong wire type or out-of-range value means the
      // payload is damaged or forged, so refuse the whole container.
      if (wire != 0) throw const OtpFormatException(OtpFormatError.malformed);
      final v = r.u32();
      if (v < 1 || v > 86400) {
        throw const OtpFormatException(OtpFormatError.malformed);
      }
      extPeriod = v;
    } else {
      r.skip(wire); // includes HOTP counter (7); type is checked below
    }
  }
  onLabels?.call(issuer, name);
  if (type != 2) throw const OtpFormatException(OtpFormatError.unsupportedType);
  final algorithm = switch (algo) {
    0 || 1 => OtpAlgorithm.sha1,
    2 => OtpAlgorithm.sha256,
    3 => OtpAlgorithm.sha512,
    _ => throw const OtpFormatException(OtpFormatError.unsupportedAlgorithm),
  };
  final d = switch (digits) {
    0 || 1 => 6,
    2 => 8,
    _ => throw const OtpFormatException(OtpFormatError.unsupportedDigits),
  };
  if (secret == null || name == null) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  // Google stores "Issuer:account" in name when issuer is also set.
  var account = name;
  if ((issuer == null || issuer.isEmpty) && name.contains(':')) {
    // Older Google exports put "Issuer:account" in the name with no issuer.
    final parts = name.split(':');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].trimLeft().isEmpty) {
      throw const OtpFormatException(OtpFormatError.malformed);
    }
    issuer = parts[0];
    account = parts[1].trimLeft();
  }
  if (issuer != null && issuer.isNotEmpty && name.startsWith('$issuer:')) {
    account = name.substring(issuer.length + 1).trimLeft();
  }
  return OtpAccount(
    issuer: (issuer == null || issuer.isEmpty) ? null : issuer,
    accountName: account,
    secret: secret,
    algorithm: algorithm,
    digits: d,
    period: extPeriod ?? 30,
    // The format never carries a period; an unspecified algorithm or digit
    // count is also a default, not something the source said.
    assumed: {
      if (extPeriod == null) OtpAssumption.period,
      if (algo == 0) OtpAssumption.algorithm,
      if (digits == 0) OtpAssumption.digits,
    },
  );
}

String _utf8(Uint8List b) {
  try {
    return utf8.decode(b);
  } catch (_) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
}

void _varint(BytesBuilder o, int v) {
  while (v > 0x7f) {
    o.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  o.addByte(v);
}

void _lenField(BytesBuilder o, int field, List<int> data) {
  _varint(o, (field << 3) | 2);
  _varint(o, data.length);
  o.add(data);
}

void _intField(BytesBuilder o, int field, int v) {
  _varint(o, field << 3);
  _varint(o, v);
}

Uint8List _encodePayload(
  List<OtpAccount> accounts,
  int size,
  int index,
  int id,
  bool periodExtension,
) {
  final o = BytesBuilder();
  for (final a in accounts) {
    final p = BytesBuilder();
    _lenField(p, 1, a.secretBytes());
    _lenField(
      p,
      2,
      utf8.encode(
        a.issuer == null ? a.accountName : '${a.issuer}:${a.accountName}',
      ),
    );
    if (a.issuer != null) _lenField(p, 3, utf8.encode(a.issuer!));
    _intField(p, 4, switch (a.algorithm) {
      OtpAlgorithm.sha1 => 1,
      OtpAlgorithm.sha256 => 2,
      OtpAlgorithm.sha512 => 3,
    });
    _intField(p, 5, a.digits == 8 ? 2 : 1);
    _intField(p, 6, 2);
    if (periodExtension && a.period != 30) {
      _intField(p, otpandaPeriodField, a.period);
    }
    _lenField(o, 1, p.toBytes());
  }
  _intField(o, 2, 1);
  _intField(o, 3, size);
  _intField(o, 4, index);
  _intField(o, 5, id);
  return o.toBytes();
}
