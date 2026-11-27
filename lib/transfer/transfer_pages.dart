import 'package:material_ui/material_ui.dart';

import '../app_theme.dart';
import '../offline_totp/import_outcome.dart';
import '../offline_totp/otp_account.dart';
import 'export_encoders.dart';
import 'export_entry.dart';
import 'export_plan.dart';
import 'google_raw_export.dart';
import 'sealed_export_source.dart';
import 'import_review.dart';
import 'qr_view.dart';

/// Settings route for the section. Composition (hub entry, router allow-list)
/// belongs to the shell owner.
const settingsTransferRoute = 'settings/transfer-codes';

Widget _card(BuildContext context, String title, List<Widget> children) => Card(
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: context.pal.ink,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  ),
);

/// Settings > Transfer codes: every import and export starts here.
class TransferCodesPage extends StatelessWidget {
  const TransferCodesPage({
    super.key,
    required this.onScanImport,
    this.onImportFile,
    required this.onExport,
    required this.exportAvailability,
  });
  final VoidCallback onScanImport;

  /// Null when this platform has no file picker adapter yet.
  final VoidCallback? onImportFile;
  final VoidCallback onExport;
  final ({bool available, String? reason}) exportAvailability;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      _card(context, 'Import codes', [
        const Text(
          'Move accounts in from another app. Scan a Google Authenticator export or a normal setup QR code, or open a file. You review everything before anything is saved.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onScanImport,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan QR code'),
        ),
        if (onImportFile != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onImportFile,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import from file'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Aegis, 2FAS, Bitwarden and key-link lists. Password-protected files are not supported yet.',
          ),
        ],
      ]),
      const SizedBox(height: 12),
      _card(context, 'Export codes', [
        const Text(
          'Show your accounts as Google Authenticator export QR codes. This needs a fresh passkey confirmation. Anyone who sees these codes can generate your sign-in codes, so only open them in private.',
        ),
        if (!exportAvailability.available) ...[
          const SizedBox(height: 8),
          Text(exportAvailability.reason ?? 'Export is not available yet.'),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: exportAvailability.available ? onExport : null,
          icon: const Icon(Icons.upload_outlined),
          label: const Text('Export with passkey'),
        ),
      ]),
    ],
  );
}

String skippedLabel(SkippedEntry k) => k.accountName == null
    ? 'Entry ${k.position}'
    : (k.issuer == null ? k.accountName! : '${k.issuer} (${k.accountName})');

String skipReason(OtpFormatError e) => switch (e) {
  OtpFormatError.unsupportedType => 'counter-based or unsupported code type',
  OtpFormatError.unsupportedAlgorithm => 'unsupported algorithm',
  OtpFormatError.unsupportedDigits => 'unsupported number of digits',
  OtpFormatError.badSecret => 'the key is missing or invalid',
  _ => 'not readable',
};

String _label(ImportPreviewLike i) =>
    i.issuer == null ? i.accountName : '${i.issuer} (${i.accountName})';

typedef ImportPreviewLike = ({String? issuer, String accountName});

/// Whole-batch review before any save. Cancel (or back) saves nothing.
class ImportReviewPage extends StatefulWidget {
  const ImportReviewPage({super.key, required this.model, required this.saver});
  final ImportReviewModel model;
  final ImportSaver saver;
  @override
  State<ImportReviewPage> createState() => _ImportReviewState();
}

class _ImportReviewState extends State<ImportReviewPage> {
  bool busy = false;
  String message = '';

  Future<void> save() async {
    final chosen = widget.model.selected();
    if (busy || chosen.isEmpty) return;
    setState(() {
      busy = true;
      message = '';
    });
    ImportSaveOutcome o;
    try {
      o = await widget.saver.save(chosen);
    } catch (_) {
      o = ImportSaveOutcome.unknown;
    }
    if (!mounted) return;
    setState(() => busy = false);
    switch (o) {
      case ImportSaveOutcome.saved:
        Navigator.of(context).pop(true);
      case ImportSaveOutcome.notSaved:
        setState(() => message = 'Nothing was saved. You can try again.');
      case ImportSaveOutcome.cancelled:
        setState(() => message = 'Cancelled. Nothing was saved.');
      case ImportSaveOutcome.unknown:
        setState(
          () => message = 'We could not confirm the result. Check your accounts list before trying again.',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final multi = m.selectedCount > 1;
    final blocked = multi && !widget.saver.atomic;
    return Scaffold(
      appBar: AppBar(title: const Text('Review import')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${m.items.length} ${m.items.length == 1 ? 'account' : 'accounts'} found'
            '${m.duplicateCount > 0 ? ', ${m.duplicateCount} already here' : ''}. Nothing is saved until you confirm.',
          ),
          if (m.hasNonDefaultPeriod)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Some codes use a custom period.'),
            ),
          const SizedBox(height: 8),
          for (var i = 0; i < m.items.length; i++)
            CheckboxListTile(
              value: m.include[i],
              onChanged: busy ? null : (_) => setState(() => m.toggle(i)),
              title: Text(
                _label((
                  issuer: m.items[i].issuer,
                  accountName: m.items[i].accountName,
                )),
              ),
              subtitle: Text(
                '${m.items[i].digits} digits, every ${m.items[i].period} s'
                '${m.items[i].assumed.isEmpty ? '' : ' (${m.items[i].assumed.map((a) => a.name).join(', ')} assumed, you can change it later)'}'
                '${m.items[i].duplicateOfExisting ? ', already added' : ''}',
              ),
            ),
          if (m.skipped.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${m.skipped.length} ${m.skipped.length == 1 ? 'entry' : 'entries'} cannot be imported:',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final k in m.skipped)
              Text('${skippedLabel(k)}: ${skipReason(k.error)}'),
          ],
          if (blocked)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Importing several accounts at once is not available yet. Select one account, or wait for the next update.',
              ),
            ),
          if (message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(message),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: busy || m.selectedCount == 0 || blocked ? null : save,
            child: Text(
              busy
                  ? 'Saving...'
                  : 'Import ${m.selectedCount} ${m.selectedCount == 1 ? 'account' : 'accounts'}',
            ),
          ),
          TextButton(
            onPressed: busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// Saves text the user chose to export (a file save or share sheet owned by
/// the shell). Must never log or copy. Returns true when the user saved it.
typedef ExportFileSaver = Future<bool> Function(String fileName, String text);

/// Reauth, then Google export QR codes, and optionally files in other formats.
/// Secrets stay in memory while this page is open and are dropped on dispose and
/// when the app leaves the foreground.
class ExportCodesPage extends StatefulWidget {
  const ExportCodesPage({
    super.key,
    this.source,
    this.entries,
    this.batchId = 1,
    this.saveFile,
    this.newUuid,
  }) : assert((source == null) != (entries == null));

  /// Exactly one of [source] (accounts, older shape) and [entries] (raw entries
  /// from the sealed export, which keep their exact label text) is given.
  final SeedExportSource? source;
  final ExportEntrySource? entries;
  final int batchId;

  /// When null the file formats are not offered (no save adapter on this
  /// platform yet).
  final ExportFileSaver? saveFile;

  /// Fresh version-4 UUID per call, for Aegis and Bitwarden files.
  final String Function()? newUuid;
  @override
  State<ExportCodesPage> createState() => _ExportState();
}

class _ExportState extends State<ExportCodesPage> with WidgetsBindingObserver {
  List<ExportedEntry>? held;
  List<ExportedEntry> blocked = const [];
  List<ExportedEntry> caution = const [];
  bool catalogNote = false;
  bool displayNameNote = false;
  List<String>? uris;
  List<GoogleExportNote> notes = const [];
  int shown = 0;
  bool busy = false;
  String message = '';
  int exportGeneration = 0;
  bool foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    foreground = s == AppLifecycleState.resumed;
    if (!foreground) _drop();
  }

  void _endSourceAttempt() {
    final Object? s = widget.entries ?? widget.source;
    if (s is ExportCancelable) s.cancel();
  }

  void _release() {
    final h = held;
    held = null;
    if (h != null) {
      for (final e in h) {
        e.dispose();
      }
    }
  }

  void _drop() {
    ++exportGeneration;
    _endSourceAttempt();
    _release();
    if (mounted) {
      setState(() {
        blocked = const [];
        caution = const [];
        catalogNote = false;
        displayNameNote = false;
        uris = null;
        notes = const [];
        shown = 0;
        message = 'Hidden. Confirm with your passkey to show the codes again.';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++exportGeneration;
    _endSourceAttempt();
    _release();
    uris = null;
    super.dispose();
  }

  Future<void> start() async {
    if (busy || !foreground) return;
    final generation = ++exportGeneration;
    bool active() => mounted && foreground && generation == exportGeneration;
    setState(() {
      busy = true;
      message = '';
    });
    List<ExportedEntry>? all;
    try {
      final raw = widget.entries;
      if (raw != null) {
        all = await raw.exportEntries();
      } else {
        final accounts = await widget.source!.exportAll();
        all = [
          for (var i = 0; i < accounts.length; i++)
            ExportedEntry.fromAccount(accounts[i], 'a$i'),
        ];
      }
      if (!active()) {
        // A late result is never shown and its secrets are overwritten.
        for (final e in all) {
          e.dispose();
        }
        return;
      }
      final g = planGoogleRawExport(all, batchId: widget.batchId);
      final u = g.uris;
      final plan = g.notes;
      if (!mounted) {
        for (final e in all) {
          e.dispose();
        }
        return;
      }
      final keep = all;
      all = null;
      setState(() {
        held = keep;
        blocked = g.blocked;
        caution = googleDisplayCaution(keep);
        catalogNote = keep.any((e) => e.catalogId != null);
        displayNameNote = keep.any((e) => e.labelDiffers);
        uris = u;
        notes = plan;
        shown = 0;
        message = g.blocked.isEmpty && u == null
            ? 'There are no accounts to export.'
            : '';
      });
    } on ExportAuthException catch (e) {
      if (mounted) {
        setState(
          () => message = e.outcome == ExportAuthOutcome.cancelled
              ? 'Cancelled. Nothing was shown.'
              : 'Confirmation failed. Nothing was shown.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Export failed. Nothing was shown.');
      }
    } finally {
      if (all != null) {
        for (final e in all) {
          e.dispose();
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save(ExportFileFormat f, String name) async {
    final all = held, saver = widget.saveFile, uuid = widget.newUuid;
    if (all == null || saver == null || uuid == null || busy) return;
    setState(() => busy = true);
    try {
      final enc = encodeExportEntries(f, all, newUuid: uuid);
      final text = enc.text;
      if (text == null) {
        if (mounted) {
          setState(
            () => message =
                'Not saved. This format cannot hold the text of ${enc.unencodable.length} account${enc.unencodable.length == 1 ? '' : 's'} exactly: ${enc.unencodable.map((e) => showSafely(e.label ?? e.accountName)).join(', ')}. Nothing was changed. Try Bitwarden JSON or Aegis.',
          );
        }
      } else {
        final ok = await saver(name, text);
        final extra = [
          if (enc.notCarried.contains(ExportNotCarried.displayName)) 'Display names that differ from the account name are not in this format.',
          if (enc.notCarried.contains(ExportNotCarried.catalogId))
            'Catalog links are not included.',
        ].join(' ');
        if (mounted) {
          setState(
            () => message = ok
                ? (extra.isEmpty ? 'File saved.' : 'File saved. $extra')
                : 'Not saved.',
          );
        }
      }
    } catch (_) {
      if (mounted) setState(() => message = 'Could not save the file.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _what(GoogleExportNote n) => switch (n.change) {
    GoogleExportChange.periodDropped =>
      'uses ${n.from} s codes. Google Authenticator will use 30 s, so its codes will not match',
    GoogleExportChange.digitsAdjusted =>
      'uses ${n.from} digits. Google Authenticator will use 6',
  };

  @override
  Widget build(BuildContext context) {
    final u = uris;
    return Scaffold(
      appBar: AppBar(title: const Text('Export codes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (held == null) ...[
            const Text(
              'You will confirm with your passkey. Then your accounts appear as QR codes you scan with Google Authenticator. Make sure nobody can see your screen.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : start,
              child: Text(busy ? 'Waiting...' : 'Confirm with passkey'),
            ),
          ] else ...[
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Google Authenticator cannot keep ${notes.length == 1 ? 'one setting' : '${notes.length} settings'} exactly. They are exported anyway, and those accounts may show different codes in Google Authenticator:',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final n in notes)
                Text(
                  '${n.issuer == null ? n.accountName : '${n.issuer} (${n.accountName})'} ${_what(n)}.',
                ),
            ],
            if (blocked.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'No QR code was made. ${blocked.length} account${blocked.length == 1 ? '' : 's'} cannot be written into one: ${blocked.map((e) => showSafely(e.label ?? e.accountName)).join(', ')}. The text is not valid Unicode or is too large for a QR. Nothing was changed.${widget.saveFile != null && widget.newUuid != null ? ' You can save a file instead.' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            if (u != null && caution.isNotEmpty)
              Text(
                'Google Authenticator may show these names differently (colons, spaces at the ends, or hidden characters): ${caution.map((e) => showSafely(e.label ?? e.accountName)).join(', ')}. The text is exported unchanged.',
              ),
            if (u != null && displayNameNote)
              const Text(
                'Display names that differ from the account name are not carried by Google Authenticator.',
              ),
            if (u != null && catalogNote)
              const Text('Catalog links are not included.'),
            const SizedBox(height: 12),
            if (u != null) ...[
              Text(
                'QR code ${shown + 1} of ${u.length}. Scan each one in Google Authenticator.',
              ),
              const SizedBox(height: 12),
              Center(child: QrView(u[shown])),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  OutlinedButton(
                    onPressed: shown > 0 ? () => setState(() => shown--) : null,
                    child: const Text('Previous'),
                  ),
                  OutlinedButton(
                    onPressed: shown < u.length - 1
                        ? () => setState(() => shown++)
                        : null,
                    child: const Text('Next'),
                  ),
                ],
              ),
            ],
            if (widget.saveFile != null && widget.newUuid != null) ...[
              const SizedBox(height: 12),
              const Text(
                'Or save a file for another app. Files hold your keys in plain text, so keep them private and delete them after use.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => save(
                            ExportFileFormat.aegisPlain,
                            'otpanda-aegis.json',
                          ),
                    child: const Text('Aegis'),
                  ),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => save(
                            ExportFileFormat.bitwardenJson,
                            'otpanda-bitwarden.json',
                          ),
                    child: const Text('Bitwarden JSON'),
                  ),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => save(
                            ExportFileFormat.bitwardenCsv,
                            'otpanda-bitwarden.csv',
                          ),
                    child: const Text('Bitwarden CSV'),
                  ),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => save(
                            ExportFileFormat.otpauthList,
                            'otpanda-keys.txt',
                          ),
                    child: const Text('Key links'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(exportMetadataNote),
            ],
            TextButton(onPressed: _drop, child: const Text('Hide codes')),
          ],
          if (message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(message),
            ),
        ],
      ),
    );
  }
}
