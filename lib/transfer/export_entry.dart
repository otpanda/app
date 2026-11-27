import 'dart:typed_data';

import '../offline_totp/otp_account.dart';

/// One exported key exactly as the server sealed it. Label, account, issuer and
/// catalog id keep their raw text through decrypt (no trimming, escaping or
/// replacement). Each file or QR format then decides, by its own rules in
/// export_encoders.dart, whether it can write them exactly.
///
/// Owns its secret bytes: [dispose] overwrites them. Dart cannot erase the
/// Strings, the JSON-decoded response, BigInts or copies the garbage collector
/// made, so this is best effort and says so.
final class ExportedEntry {
  ExportedEntry({
    required this.entryId,
    required this.label,
    required this.account,
    required this.issuer,
    required this.catalogId,
    required this.algorithm,
    required this.digits,
    required this.period,
    required Uint8List secret,
  }) : _secret = secret; // ignore: prefer_initializing_formals

  /// An account from a source that has no separate display name.
  factory ExportedEntry.fromAccount(OtpAccount a, String entryId) =>
      ExportedEntry(
        entryId: entryId,
        label: a.accountName,
        account: a.accountName,
        issuer: a.issuer,
        catalogId: null,
        algorithm: a.algorithm,
        digits: a.digits,
        period: a.period,
        secret: a.secretBytes(),
      );

  final String entryId;
  final String? label, account, issuer, catalogId;
  final OtpAlgorithm algorithm;
  final int digits, period;
  Uint8List? _secret;

  bool get disposed => _secret == null;

  /// A copy. The caller overwrites it after use.
  Uint8List secretBytes() {
    final s = _secret;
    if (s == null) throw StateError('export entry disposed');
    return Uint8List.fromList(s);
  }

  void dispose() {
    _secret?.fillRange(0, _secret!.length, 0);
    _secret = null;
  }

  /// The name formats call "account": the account text, or the display name
  /// when the account is empty, or the id as the last resort.
  String get accountName =>
      (account != null && account!.isNotEmpty) ? account! : (label ?? entryId);

  /// The issuer, or null when absent or empty.
  String? get issuerOrNull =>
      (issuer == null || issuer!.isEmpty) ? null : issuer;

  /// True when [label] is text a format with no display-name field would lose.
  bool get labelDiffers => label != null && label != accountName;

  /// The account model, or null when it cannot hold this text exactly
  /// (control, bidi, colon, edge space, over-long names). Never alters text.
  OtpAccount? toAccountOrNull() {
    try {
      return OtpAccount(
        issuer: issuerOrNull,
        accountName: accountName,
        secret: secretBytes(),
        algorithm: algorithm,
        digits: digits,
        period: period,
      );
    } on OtpFormatException {
      return null;
    }
  }
}

/// A source of raw export entries (the sealed export route). Implemented by
/// [SealedSeedExportSource]; the page also accepts the older account source.
abstract interface class ExportEntrySource {
  ({bool available, String? reason}) get availability;
  Future<List<ExportedEntry>> exportEntries();
}

/// Text for the screen only: control and bidi characters shown as \uXXXX so a
/// name cannot hide or reorder what the user reads. Never used in a file.
String showSafely(String? v, {int max = 60}) {
  if (v == null) return '(none)';
  final b = StringBuffer();
  for (final r in v.runes) {
    final bad =
        r < 0x20 ||
        (r >= 0x7f && r <= 0x9f) ||
        r == 0xad ||
        r == 0x61c ||
        r == 0x180e ||
        (r >= 0x200b && r <= 0x200f) ||
        (r >= 0x2028 && r <= 0x202e) ||
        (r >= 0x2060 && r <= 0x206f) ||
        (r >= 0xd800 && r <= 0xdfff) ||
        r == 0xfeff ||
        (r >= 0xfff9 && r <= 0xfffb);
    b.write(
      bad
          ? '\\u${r.toRadixString(16).padLeft(4, '0')}'
          : String.fromCharCode(r),
    );
  }
  final s = b.toString();
  return s.length > max ? '${s.substring(0, max)}...' : s;
}

/// True when [s] has an unpaired surrogate, which no UTF-8 file can hold.
bool hasLoneSurrogate(String s) {
  final u = s.codeUnits;
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      if (i + 1 < u.length && u[i + 1] >= 0xdc00 && u[i + 1] <= 0xdfff) {
        i++;
        continue;
      }
      return true;
    }
    if (c >= 0xdc00 && c <= 0xdfff) return true;
  }
  return false;
}
