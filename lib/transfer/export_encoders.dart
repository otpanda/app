import 'dart:convert';

import '../offline_totp/base32.dart';
import '../offline_totp/otp_account.dart';
import 'export_entry.dart';
import 'export_plan.dart' show ExportFileFormat;

/// Result of writing one file format from raw entries.
///
/// [text] is null when the format cannot write some entry's text exactly. The
/// whole file is then withheld (never a partial file) and [unencodable] names
/// the entries so the owner can fix them or choose another format. [notCarried]
/// lists metadata the format has no place for, so nothing is lost silently.
final class ExportEncoding {
  const ExportEncoding({
    this.text,
    this.unencodable = const [],
    this.notCarried = const {},
  });
  final String? text;
  final List<ExportedEntry> unencodable;
  final Set<ExportNotCarried> notCarried;
}

enum ExportNotCarried {
  /// OTPanda's display name, in a format with no field for it.
  displayName,

  /// OTPanda's catalog id, which no other app has a field for.
  catalogId,
}

String _alg(OtpAlgorithm a) => switch (a) {
  OtpAlgorithm.sha1 => 'SHA1',
  OtpAlgorithm.sha256 => 'SHA256',
  OtpAlgorithm.sha512 => 'SHA512',
};

bool _badText(ExportedEntry e) =>
    [e.label, e.account, e.issuer].any((v) => v != null && hasLoneSurrogate(v));

/// otpauth key URI. The label is percent-encoded text, so any text is exact.
/// The display name has no place in it when it differs from the account name.
String otpauthUriOf(ExportedEntry e) {
  final issuer = e.issuerOrNull;
  final label = issuer == null
      ? Uri.encodeComponent(e.accountName)
      : '${Uri.encodeComponent(issuer)}:${Uri.encodeComponent(e.accountName)}';
  final q = [
    'secret=${encodeBase32(e.secretBytes())}',
    if (issuer != null) 'issuer=${Uri.encodeComponent(issuer)}',
    'algorithm=${_alg(e.algorithm)}',
    'digits=${e.digits}',
    'period=${e.period}',
  ];
  return 'otpauth://totp/$label?${q.join('&')}';
}

final _formula = RegExp(r'^[=+\-@\t\r]');

/// Writes [format] from raw entries. Pure: [newUuid] supplies fresh UUIDs.
ExportEncoding encodeExportEntries(
  ExportFileFormat format,
  List<ExportedEntry> entries, {
  required String Function() newUuid,
}) {
  final notCarried = <ExportNotCarried>{
    if (entries.any((e) => e.catalogId != null)) ExportNotCarried.catalogId,
  };
  final bad = [
    for (final e in entries)
      if (_badText(e)) e,
  ];
  if (bad.isNotEmpty) return ExportEncoding(unencodable: bad);

  switch (format) {
    case ExportFileFormat.otpauthList:
      return ExportEncoding(
        text: entries.map(otpauthUriOf).join('\n'),
        notCarried: {
          ...notCarried,
          if (entries.any((e) => e.labelDiffers)) ExportNotCarried.displayName,
        },
      );
    case ExportFileFormat.aegisPlain:
      // Aegis keeps the display name in its free-text note when it differs.
      return ExportEncoding(
        text: const JsonEncoder.withIndent('  ').convert({
          'version': 1,
          'header': {'slots': null, 'params': null},
          'db': {
            'version': 3,
            'entries': [
              for (final e in entries)
                {
                  'type': 'totp',
                  'uuid': newUuid(),
                  'name': e.accountName,
                  'issuer': e.issuerOrNull ?? '',
                  'note': e.labelDiffers ? e.label : '',
                  'icon': null,
                  'icon_mime': null,
                  'icon_hash': null,
                  'favorite': false,
                  'info': {
                    'secret': encodeBase32(e.secretBytes()),
                    'algo': _alg(e.algorithm),
                    'digits': e.digits,
                    'period': e.period,
                  },
                  'groups': <String>[],
                },
            ],
            'groups': <Object>[],
          },
        }),
        notCarried: notCarried,
      );
    case ExportFileFormat.bitwardenJson:
      return ExportEncoding(
        text: const JsonEncoder.withIndent('  ').convert({
          'encrypted': false,
          'items': [
            for (final e in entries)
              {
                'favorite': false,
                'id': newUuid(),
                'login': {'totp': otpauthUriOf(e), 'username': e.accountName},
                'name': e.issuerOrNull ?? e.accountName,
                'notes': e.labelDiffers ? e.label : null,
                'type': 1,
              },
          ],
        }),
        notCarried: notCarried,
      );
    case ExportFileFormat.bitwardenCsv:
      // A spreadsheet reads a leading = + - @ tab or CR as a formula, and a
      // NUL breaks readers. Those texts cannot be written exactly, so the
      // whole CSV is withheld and JSON is the way to export them.
      String name(ExportedEntry e) => e.issuerOrNull ?? e.accountName;
      String? note(ExportedEntry e) => e.labelDiffers ? e.label : null;
      final risky = [
        for (final e in entries)
          if ([
            name(e),
            e.accountName,
            note(e) ?? '',
          ].any((v) => _formula.hasMatch(v) || v.contains('\u0000')))
            e,
      ];
      if (risky.isNotEmpty) return ExportEncoding(unencodable: risky);
      String q(String v) =>
          RegExp(r'[",\r\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
      final lines = [
        'folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp',
        for (final e in entries)
          ',,login,${q(name(e))},${q(note(e) ?? '')},,0,,${q(e.accountName)},,${q(otpauthUriOf(e))}',
      ];
      return ExportEncoding(
        text: '${lines.join('\n')}\n',
        notCarried: notCarried,
      );
  }
}
