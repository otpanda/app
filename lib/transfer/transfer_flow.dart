import 'package:material_ui/material_ui.dart';

import '../offline_totp/import_outcome.dart';
import '../offline_totp/otp_account.dart';
import '../offline_totp/otpauth_uri.dart';
import 'export_entry.dart';
import 'import_formats.dart';
import 'import_review.dart';
import 'transfer_pages.dart';
import 'universal_scanner.dart';

/// Shell-owned composition, no seed access until the export page's explicit
/// confirmation. The shell supplies owner-bound saver/source and retires this
/// widget when its verified session or local-unlock generation changes.
class TransferFlow extends StatefulWidget {
  const TransferFlow({
    super.key,
    required this.saver,
    required this.exportSource,
    this.existing = const {},
    this.readFile,
    this.onSaved,
  });
  final ImportSaver saver;
  final ExportEntrySource exportSource;
  final Set<(String?, String)> existing;
  final Future<String?> Function()? readFile;
  final Future<void> Function()? onSaved;
  @override
  State<TransferFlow> createState() => _TransferFlowState();
}

class _TransferFlowState extends State<TransferFlow> {
  String message = '';
  bool busy = false;
  Future<void> review(ImportOutcome outcome) async {
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ImportReviewPage(
          model: ImportReviewModel.fromOutcome(
            outcome,
            existing: widget.existing,
          ),
          saver: widget.saver,
        ),
      ),
    );
    if (saved == true) await widget.onSaved?.call();
  }

  Future<void> scan() async {
    final result = await Navigator.of(context).push<ScanOutcome>(
      MaterialPageRoute(builder: (_) => const UniversalScannerPage()),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case ScannedMigration(:final outcome):
        await review(outcome);
      case ScannedSingle(:final value):
        try {
          await review(ImportOutcome([parseOtpauthUri(value.uri)], const []));
        } on OtpFormatException {
          if (mounted) {
            setState(() => message = 'That setup code could not be imported.');
          }
        }
    }
  }

  Future<void> file() async {
    if (busy || widget.readFile == null) return;
    setState(() => busy = true);
    try {
      final text = await widget.readFile!();
      if (text != null && mounted) await review(parseImportFile(text));
    } on OtpFormatException catch (e) {
      if (mounted) {
        setState(
          () => message = e.error == OtpFormatError.encrypted
              ? 'Password-protected files are not supported yet.'
              : 'That file could not be imported. Nothing was saved.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Could not open the file. Nothing was saved.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (message.isNotEmpty)
        Padding(padding: const EdgeInsets.all(16), child: Text(message)),
      Expanded(
        child: TransferCodesPage(
          onScanImport: scan,
          onImportFile: widget.readFile == null ? null : file,
          exportAvailability: widget.exportSource.availability,
          onExport: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Export codes')),
                body: ExportCodesPage(entries: widget.exportSource),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
