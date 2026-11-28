import 'package:material_ui/material_ui.dart';

import '../app_theme.dart';
import '../offline_totp/import_outcome.dart';
import '../offline_totp/otp_account.dart';
import 'import_review.dart';

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

/// Settings > Transfer codes (import only in this slice; export is not mounted).
class TransferCodesPage extends StatelessWidget {
  const TransferCodesPage({
    super.key,
    required this.onScanImport,
    this.onImportFile,
  });
  final VoidCallback onScanImport;

  /// Null when this platform has no file picker adapter yet.
  final VoidCallback? onImportFile;

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
  ImportSaveOutcome? result;
  Future<bool> Function()? acknowledgeResult;

  Future<void> save() async {
    final chosen = widget.model.selected();
    if (busy || chosen.isEmpty) return;
    setState(() {
      busy = true;
      message = '';
    });
    ImportSaveOutcome o;
    try {
      final s = widget.saver;
      o = result == ImportSaveOutcome.unknown && s is RecoverableImportSaver
          ? await s.reconcile()
          : await s.save(chosen);
    } catch (_) {
      o = ImportSaveOutcome.unknown;
    }
    if (!mounted) return;
    final source = widget.saver;
    acknowledgeResult = source is ImportAcknowledgementSource
        ? (source as ImportAcknowledgementSource).captureShownAcknowledgement()
        : null;
    setState(() {
      busy = false;
      result = o;
    });
    switch (o) {
      case ImportSaveOutcome.blocked:
        setState(
          () => message = 'A previous import needs recovery, or import recovery is unavailable. This selection was not submitted. Return to Transfer codes to continue recovery.',
        );
      case ImportSaveOutcome.capacity:
        setState(
          () => message = 'Import is busy right now. This selection was not submitted. Try again later.',
        );
      case ImportSaveOutcome.saved:
        setState(() => message = 'Import saved.');
      case ImportSaveOutcome.notSaved:
        setState(() => message = 'Nothing was saved. You can try again.');
      case ImportSaveOutcome.cancelled:
        setState(() => message = 'Cancelled. Nothing was saved.');
      case ImportSaveOutcome.unknown:
        setState(
          () => message = 'We could not confirm the result. Do not import again. Check recovery to find out whether it was saved.',
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
            '${m.duplicateCount > 0 ? ', ${m.duplicateCount} possible duplicates' : ''}. Nothing is saved until you confirm.',
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
                '${m.items[i].duplicateOfExisting ? ', possible duplicate' : ''}',
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
          if (result == ImportSaveOutcome.blocked)
            const SizedBox.shrink()
          else if (result == ImportSaveOutcome.saved ||
              result == ImportSaveOutcome.notSaved)
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      try {
                        final s = widget.saver;
                        final ack = acknowledgeResult;
                        final accepted = ack != null
                            ? await ack()
                            : s is RecoverableImportSaver
                            ? await s.acknowledgeShown()
                            : true;
                        if (!accepted) {
                          throw StateError('acknowledgement_unavailable');
                        }
                      } catch (_) {
                        if (mounted) {
                          setState(
                            () => message = 'Could not acknowledge the result. Your recovery record has been kept.',
                          );
                        }
                        return;
                      }
                      if (context.mounted) {
                        Navigator.of(context)
                            .pop(result == ImportSaveOutcome.saved);
                      }
                    },
              child: const Text('Got it'),
            )
          else
            FilledButton(
              onPressed: busy || m.selectedCount == 0 || blocked ? null : save,
              child: Text(
                result == ImportSaveOutcome.unknown
                    ? 'Check recovery'
                    : busy
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
