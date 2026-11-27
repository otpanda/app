import 'dart:convert';
import 'dart:typed_data';

import '../offline_totp/google_migration.dart'
    show otpandaDigitsField, otpandaPeriodField, maxAccountsPerBatch;
import '../offline_totp/otp_account.dart' show OtpAlgorithm;
import 'export_entry.dart';
import 'export_plan.dart'
    show GoogleExportChange, GoogleExportNote, maxExportQrChars;

/// Google Authenticator migration QR written straight from raw entries. The
/// issuer and account text go into the protobuf as UTF-8 exactly as decrypted.
/// No account model is built, and nothing is trimmed, escaped or replaced.
///
/// Only real limits stop it: text that is not well formed Unicode (an unpaired
/// surrogate has no UTF-8 form), and one account too large for a QR that phones
/// scan reliably ([maxExportQrChars]). Those entries are listed in [blocked]
/// and no QR is made for the batch, so nothing is silently left out.
///
/// What Google Authenticator does with a colon, edge space, control or bidi
/// text, or a very long name is NOT verified. The wire carries the text; the
/// page only cautions that names may show differently ([googleDisplayCaution]).
///
/// Wire: field 1 secret, 2 name (`issuer:account` when there is an issuer,
/// else the account), 3 issuer, 4 algorithm enum, 5 digits enum (eight stays
/// eight; six and seven are written as six), 6 type TOTP. OTPanda extension
/// fields: 15 period when not 30 s and 16 digits when 7. The display name and
/// catalog id have no field and are not carried.
final class GoogleRawExport {
  const GoogleRawExport({
    required this.uris,
    required this.notes,
    required this.blocked,
  });

  /// Null when [blocked] is not empty or there is nothing to export.
  final List<String>? uris;
  final List<GoogleExportNote> notes;
  final List<ExportedEntry> blocked;
}

bool _wellFormed(ExportedEntry e) =>
    !hasLoneSurrogate(e.accountName) &&
    (e.issuerOrNull == null || !hasLoneSurrogate(e.issuerOrNull!));

void _varint(BytesBuilder o, int v) {
  while (v > 0x7f) {
    o.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  o.addByte(v);
}

void _len(BytesBuilder o, int field, List<int> data) {
  _varint(o, (field << 3) | 2);
  _varint(o, data.length);
  o.add(data);
}

void _int(BytesBuilder o, int field, int v) {
  _varint(o, field << 3);
  _varint(o, v);
}

Uint8List _payload(List<ExportedEntry> es, int size, int index, int id) {
  final o = BytesBuilder();
  for (final e in es) {
    final p = BytesBuilder();
    final secret = e.secretBytes();
    _len(p, 1, secret);
    secret.fillRange(0, secret.length, 0);
    final issuer = e.issuerOrNull;
    _len(
      p,
      2,
      utf8.encode(issuer == null ? e.accountName : '$issuer:${e.accountName}'),
    );
    if (issuer != null) _len(p, 3, utf8.encode(issuer));
    _int(p, 4, switch (e.algorithm) {
      OtpAlgorithm.sha1 => 1,
      OtpAlgorithm.sha256 => 2,
      OtpAlgorithm.sha512 => 3,
    });
    _int(p, 5, e.digits == 8 ? 2 : 1);
    _int(p, 6, 2);
    if (e.digits == 7) _int(p, otpandaDigitsField, 7);
    if (e.period != 30) _int(p, otpandaPeriodField, e.period);
    _len(o, 1, p.toBytes());
  }
  _int(o, 2, 1);
  _int(o, 3, size);
  _int(o, 4, index);
  _int(o, 5, id);
  return o.toBytes();
}

String _uri(List<ExportedEntry> es, int size, int index, int id) =>
    'otpauth-migration://offline?data=${Uri.encodeQueryComponent(base64.encode(_payload(es, size, index, id)))}';

/// Plans and encodes the whole batch. [batchId] must be fresh per export.
GoogleRawExport planGoogleRawExport(
  List<ExportedEntry> entries, {
  required int batchId,
}) {
  final notes = <GoogleExportNote>[
    for (final e in entries) ...[
      if (e.period != 30)
        GoogleExportNote(
          e.issuerOrNull,
          e.accountName,
          GoogleExportChange.periodDropped,
          e.period,
        ),
      if (e.digits != 6 && e.digits != 8)
        GoogleExportNote(
          e.issuerOrNull,
          e.accountName,
          GoogleExportChange.digitsAdjusted,
          e.digits,
        ),
    ],
  ];
  final blocked = [
    for (final e in entries)
      if (!_wellFormed(e) || _uri([e], 1, 0, batchId).length > maxExportQrChars)
        e,
  ];
  if (blocked.isNotEmpty || entries.isEmpty) {
    return GoogleRawExport(uris: null, notes: notes, blocked: blocked);
  }
  for (
    var per = maxAccountsPerBatch < 10 ? maxAccountsPerBatch : 10;
    per >= 1;
    per--
  ) {
    final chunks = [
      for (var i = 0; i < entries.length; i += per)
        entries.sublist(i, i + per > entries.length ? entries.length : i + per),
    ];
    final uris = [
      for (var i = 0; i < chunks.length; i++)
        _uri(chunks[i], chunks.length, i, batchId),
    ];
    if (uris.every((u) => u.length <= maxExportQrChars)) {
      return GoogleRawExport(uris: uris, notes: notes, blocked: const []);
    }
  }
  // Every single entry fit alone, so this is not reachable; fail closed.
  return GoogleRawExport(uris: null, notes: notes, blocked: entries);
}

/// Entries whose names Google Authenticator may show differently from what is
/// stored: a colon (it also separates issuer and account), leading or trailing
/// space, control or bidi characters. A caution only, not a claim that Google
/// rejects them.
List<ExportedEntry> googleDisplayCaution(List<ExportedEntry> entries) {
  final odd = RegExp(
    r'[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff\ufff9-\ufffb:]',
  );
  bool bad(String? v) => v != null && (odd.hasMatch(v) || v != v.trim());
  return [
    for (final e in entries)
      if (bad(e.accountName) || bad(e.issuerOrNull)) e,
  ];
}
