import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:material_ui/material_ui.dart';

import 'qr_camera_problem.dart';
import 'qr_decode.dart';

/// Android/desktop camera preview that decodes QR codes with the pure-Dart
/// decoder. No Google services, no bundled models.
class QrCameraView extends StatefulWidget {
  const QrCameraView({super.key, required this.onText, required this.onError});
  final void Function(String text) onText;
  final void Function(QrCameraProblem problem) onError;
  @override
  State<QrCameraView> createState() => _QrCameraViewState();
}

class _QrCameraViewState extends State<QrCameraView> {
  CameraController? _controller;
  bool _busy = false;
  bool _disposed = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        widget.onError(QrCameraProblem.unavailable);
        return;
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final c = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await c.initialize();
      if (_disposed) {
        await c.dispose();
        return;
      }
      _controller = c;
      if (mounted) setState(() {});
      await c.startImageStream(_onFrame);
    } on CameraException catch (e) {
      widget.onError(
        e.code.toLowerCase().contains('access')
            ? QrCameraProblem.permissionDenied
            : QrCameraProblem.unavailable,
      );
    } catch (_) {
      widget.onError(QrCameraProblem.unavailable);
    }
  }

  void _onFrame(CameraImage image) {
    final now = DateTime.now();
    if (_busy || now.difference(_last).inMilliseconds < 150) return;
    _busy = true;
    _last = now;
    final plane = image.planes.first;
    final bytes = Uint8List.fromList(plane.bytes);
    final stride = plane.bytesPerRow, w = image.width, h = image.height;
    Isolate.run(() => decodeQrLuma(bytes, stride, w, h))
        .then((text) {
          if (text != null && !_disposed) widget.onText(text);
        })
        .whenComplete(() => _busy = false);
  }

  @override
  void dispose() {
    _disposed = true;
    final c = _controller;
    if (c != null) {
      if (c.value.isStreamingImages) {
        unawaited(c.stopImageStream().whenComplete(c.dispose));
      } else {
        unawaited(c.dispose());
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return CameraPreview(c);
  }
}
