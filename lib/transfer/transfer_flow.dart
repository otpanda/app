import 'package:material_ui/material_ui.dart';

import '../offline_totp/import_outcome.dart';
import '../offline_totp/otp_account.dart';
import '../offline_totp/otpauth_uri.dart';
import 'import_formats.dart';
import 'import_review.dart';
import 'transfer_pages.dart';
import 'universal_scanner.dart';

/// Import-only shell-owned composition. The shell supplies owner-bound saver/source and retires this
/// widget when its verified session or local-unlock generation changes.
class TransferFlow extends StatefulWidget {
  const TransferFlow({
    super.key,
    required this.saver,
    this.existing = const {},
    this.readFile,
    this.onSaved,
    this.onReviewClosed,
  });
  final ImportSaver saver;
  final Set<(String?, String)> existing;
  final Future<String?> Function()? readFile;
  final Future<void> Function()? onSaved;
  final Future<void> Function()? onReviewClosed;
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
    try {
      if (saved == true) await widget.onSaved?.call();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Import saved, but the accounts list could not refresh.',
        );
      }
    } finally {
      await widget.onReviewClosed?.call();
    }
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
        ),
      ),
    ],
  );
}
