import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'otpauth.dart';
import 'qr_camera.dart';

/// Opens a camera scanner and returns the first valid otpauth import, or null
/// if cancelled. Replaceable in tests.
typedef OtpauthScan = Future<OtpauthImport?> Function(BuildContext context);

Future<OtpauthImport?> scanOtpauth(BuildContext context) =>
    Navigator.of(context).push<OtpauthImport>(
      MaterialPageRoute(builder: (_) => const OtpauthScannerPage()),
    );

class OtpauthScannerPage extends StatefulWidget {
  const OtpauthScannerPage({super.key});
  @override
  State<OtpauthScannerPage> createState() => _ScannerState();
}

class _ScannerState extends State<OtpauthScannerPage> {
  String error = '';
  QrCameraProblem? problem;
  bool done = false;

  void onText(String text) {
    if (done) return;
    try {
      final result = parseOtpauth(text);
      done = true;
      Navigator.of(context).pop(result);
    } on OtpauthException catch (e) {
      if (mounted && error != e.message) setState(() => error = e.message);
    }
  }

  void onProblem(QrCameraProblem p) {
    if (mounted) setState(() => problem = p);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan setup QR code')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (problem == null)
          QrCameraView(onText: onText, onError: onProblem)
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
            child: Text(
              error.isEmpty
                  ? 'Point the camera at the QR code shown by the service. The image is read on this device only.'
                  : error,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    ),
  );
}
