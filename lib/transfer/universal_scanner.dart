import 'package:material_ui/material_ui.dart';

import '../offline_totp/import_outcome.dart';
import 'migration_collection.dart';
import '../offline_totp/otp_account.dart'
    show OtpFormatError, OtpFormatException;
import '../otpauth.dart';
import '../qr_camera.dart';
import '../totp_enrollment.dart' show QrCameraBuilder;
import 'qr_import_detector.dart';

/// What the scanner hands back. Exactly one of the two.
sealed class ScanOutcome {
  const ScanOutcome();
}

/// A normal single-account setup QR: continue the existing add-key form.
final class ScannedSingle extends ScanOutcome {
  const ScannedSingle(this.value);
  final OtpauthImport value;
}

/// A complete Google export (all parts scanned): continue to batch review.
final class ScannedMigration extends ScanOutcome {
  ScannedMigration(this.outcome);
  final ImportOutcome outcome;
  @override
  String toString() => 'ScannedMigration(redacted)';
}

String migrationErrorMessage(OtpFormatError e) => switch (e) {
  OtpFormatError.conflictingMetadata => 'This QR code is from a different export. Finish the current one first, or cancel and start again.',
  OtpFormatError.tooLarge => 'This export is too large to import.',
  OtpFormatError.unsupportedType =>
    'This export has a code type that is not supported.',
  _ => 'That export QR code could not be read.',
};

/// The one scanner for adding keys. It reads the QR itself: a normal setup QR
/// completes at once; a Google export QR starts a collection that waits for
/// every part (any order, repeats ignored) before returning. Cancelling returns
/// null and nothing was saved.
class UniversalScannerPage extends StatefulWidget {
  const UniversalScannerPage({super.key, this.camera});

  /// Replaceable in tests.
  final QrCameraBuilder? camera;
  @override
  State<UniversalScannerPage> createState() => _UniversalScannerState();
}

class _UniversalScannerState extends State<UniversalScannerPage> {
  final collection = MigrationCollection();
  String error = '';
  QrCameraProblem? problem;
  bool done = false;

  void onText(String text) {
    if (done) return;
    switch (detectImportQr(text)) {
      case ImportQrKind.otpauthSingle:
        try {
          final v = parseOtpauth(text.trim());
          done = true;
          Navigator.of(context).pop<ScanOutcome>(ScannedSingle(v));
        } on OtpauthException catch (e) {
          _say(e.message);
        }
      case ImportQrKind.googleMigration:
        try {
          collection.scan(text.trim());
          if (collection.complete) {
            final outcome = collection.outcome();
            collection.clear();
            done = true;
            Navigator.of(context).pop<ScanOutcome>(ScannedMigration(outcome));
          } else if (mounted) {
            setState(() => error = '');
          }
        } on OtpFormatException catch (e) {
          _say(migrationErrorMessage(e.error));
        }
      case ImportQrKind.unknown:
        _say('That QR code is not an authenticator setup or export code.');
    }
  }

  void _say(String m) {
    if (mounted && error != m) setState(() => error = m);
  }

  @override
  void dispose() {
    collection.clear();
    super.dispose();
  }

  String get hint {
    if (error.isNotEmpty) return error;
    if (collection.collected > 0) {
      return 'Google export: scanned ${collection.collected} of ${collection.expected} QR codes. '
          'Show the next one. Order does not matter.';
    }
    return 'Point the camera at a setup QR code, or at a Google Authenticator export QR code. '
        'The image is read on this device only.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan QR code')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (problem == null)
          (widget.camera ?? (t, e) => QrCameraView(onText: t, onError: e))(
            onText,
            (p) {
              if (mounted) setState(() => problem = p);
            },
          )
        else
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                problem == QrCameraProblem.permissionDenied
                    ? 'Camera permission is off. Allow camera access in settings, or go back and enter the setup key by hand.'
                    : 'The camera is not available. Go back and enter the setup key by hand.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(hint, style: const TextStyle(color: Colors.white)),
          ),
        ),
      ],
    ),
  );
}
