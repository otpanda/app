import 'dart:convert';

import 'base32.dart';
import 'import_outcome.dart';
import 'otp_account.dart';
import 'otpauth_uri.dart';

/// Bitwarden Authenticator / Password Manager exports, plain files only.
///
/// JSON: `{"encrypted": false, "items": [{"name", "login": {"username",
/// "totp"}, ...}]}`. CSV: header with `name`, `login_username`, `login_totp`.
/// Both are shown in Bitwarden's own help page for Authenticator import and
/// export. Each `totp` value is an `otpauth://` Key URI. Password Manager files
/// can also hold a bare Base32 secret (SHA-1, 6 digits, 30 s, all marked as
/// assumptions) or a `steam://` secret (skipped as unsupported). Items with no
/// totp value are not authenticator entries and are ignored, not reported.
/// An `encrypted: true` JSON file is refused as encrypted.
ImportOutcome parseBitwardenJson(String text) {
  if (text.length > 8 << 20) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  Object? root;
  try {
    root = jsonDecode(text);
  } catch (_) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (root is! Map) throw const OtpFormatException(OtpFormatError.malformed);
  if (root['encrypted'] == true) {
    throw const OtpFormatException(OtpFormatError.encrypted);
  }
  final items = root['items'];
  if (items is! List) throw const OtpFormatException(OtpFormatError.malformed);
  if (items.length > 5000) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  final rows = <_Row>[];
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    if (it is! Map) {
      rows.add(_Row(i + 1, null, null, null, OtpFormatError.malformed));
      continue;
    }
    final login = it['login'];
    final totp = login is Map ? login['totp'] : null;
    if (totp == null || (totp is String && totp.isEmpty)) continue;
    final name = it['name'] is String ? it['name'] as String : null;
    final user = login is Map && login['username'] is String
        ? login['username'] as String
        : null;
    rows.add(
      totp is String
          ? _Row(i + 1, name, user, totp, null)
          : _Row(i + 1, name, user, null, OtpFormatError.malformed),
    );
  }
  return _convert(rows);
}

ImportOutcome parseBitwardenCsv(String text) {
  if (text.length > 8 << 20) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  final table = _csv(text.startsWith('\ufeff') ? text.substring(1) : text);
  if (table.isEmpty) throw const OtpFormatException(OtpFormatError.malformed);
  final head = table.first;
  final iName = head.indexOf('name'),
      iUser = head.indexOf('login_username'),
      iTotp = head.indexOf('login_totp');
  if (iName < 0 || iTotp < 0) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (table.length > 5001) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  final rows = <_Row>[];
  for (var n = 1; n < table.length; n++) {
    final r = table[n];
    String? at(int i) =>
        i >= 0 && i < r.length && r[i].isNotEmpty ? r[i] : null;
    final totp = at(iTotp);
    if (totp == null) {
      // A row too short to reach the totp column is damaged, not "no totp".
      if (r.length <= iTotp) {
        rows.add(_Row(n, at(iName), at(iUser), null, OtpFormatError.malformed));
      }
      continue;
    }
    rows.add(_Row(n, at(iName), at(iUser), totp, null));
  }
  return _convert(rows);
}

final class _Row {
  _Row(this.position, this.name, this.username, this.totp, this.error);
  final int position;
  final String? name, username, totp;
  final OtpFormatError? error;
}

ImportOutcome _convert(List<_Row> rows) {
  final accounts = <OtpAccount>[];
  final skipped = <SkippedEntry>[];
  for (final r in rows) {
    try {
      if (r.error != null) throw OtpFormatException(r.error!);
      accounts.add(_one(r));
    } on OtpFormatException catch (e) {
      skipped.add(
        SkippedEntry(
          r.position,
          e.error,
          issuer: null,
          accountName: displayableLabel(r.username ?? r.name),
        ),
      );
    }
  }
  if (accounts.isEmpty && skipped.isEmpty) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  return ImportOutcome(accounts, skipped);
}

OtpAccount _one(_Row r) {
  final t = r.totp!.trim();
  if (t.startsWith('otpauth://')) return parseOtpauthUri(t);
  if (t.startsWith('steam://')) {
    throw const OtpFormatException(OtpFormatError.unsupportedType);
  }
  if (!RegExp(r'^[A-Za-z2-7 ]{16,}$').hasMatch(t)) {
    throw const OtpFormatException(OtpFormatError.badSecret);
  }
  final label = r.username ?? r.name;
  if (label == null) throw const OtpFormatException(OtpFormatError.malformed);
  return OtpAccount(
    issuer: r.name != null && r.name != label ? r.name : null,
    accountName: label,
    secret: decodeBase32(t.replaceAll(' ', '').toUpperCase()),
    assumed: OtpAssumption.values.toSet(),
  );
}

/// Bitwarden Authenticator JSON export. Contains every secret: call only
/// behind strong re-authentication. [newUuid] supplies a fresh UUID per item.
String encodeBitwardenJson(
  List<OtpAccount> accounts, {
  required String Function() newUuid,
}) => const JsonEncoder.withIndent('  ').convert({
  'encrypted': false,
  'items': [
    for (final a in accounts)
      {
        'favorite': false,
        'id': newUuid(),
        'login': {'totp': encodeOtpauthUri(a), 'username': a.accountName},
        'name': a.issuer ?? a.accountName,
        'type': 1,
      },
  ],
});

/// True when a label would be read as a formula by a spreadsheet (leading
/// `=`, `+`, `-`, `@`, tab or CR). The CSV encoder refuses such accounts rather
/// than change their labels; JSON has no such problem.
bool bitwardenCsvFormulaRisk(OtpAccount a) =>
    RegExp(r'^[=+\-@\t\r]').hasMatch(a.issuer ?? '') ||
    RegExp(r'^[=+\-@\t\r]').hasMatch(a.accountName);

/// Bitwarden CSV export (same columns as Bitwarden's own Authenticator CSV).
/// Throws [OtpFormatError.notRepresentable] if any label could be read as a
/// spreadsheet formula (see [bitwardenCsvFormulaRisk]); export those as JSON.
String encodeBitwardenCsv(List<OtpAccount> accounts) {
  if (accounts.any(bitwardenCsvFormulaRisk)) {
    throw const OtpFormatException(OtpFormatError.notRepresentable);
  }
  String q(String v) =>
      RegExp(r'[",\r\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
  final lines = [
    'folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp',
    for (final a in accounts)
      ',,login,${q(a.issuer ?? a.accountName)},,,0,,${q(a.accountName)},,${q(encodeOtpauthUri(a))}',
  ];
  return '${lines.join('\n')}\n';
}

// Small RFC 4180 reader: quoted fields, doubled quotes, CR/LF/CRLF rows.
List<List<String>> _csv(String s) {
  final rows = <List<String>>[];
  var row = <String>[], f = StringBuffer();
  var quoted = false, any = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          f.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        f.write(c);
      }
    } else if (c == '"' && f.isEmpty) {
      quoted = true;
      any = true;
    } else if (c == ',') {
      row.add(f.toString());
      f = StringBuffer();
      any = true;
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
      if (any || f.isNotEmpty) {
        row.add(f.toString());
        rows.add(row);
      }
      row = <String>[];
      f = StringBuffer();
      any = false;
    } else {
      f.write(c);
      any = true;
    }
  }
  if (quoted) throw const OtpFormatException(OtpFormatError.malformed);
  if (any || f.isNotEmpty) {
    row.add(f.toString());
    rows.add(row);
  }
  return rows;
}
