import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:material_ui/material_ui.dart';
import 'package:web/web.dart' as web;

import 'qr_camera_problem.dart';

const _scriptUrl = 'assets/assets/zxing/zxing-library-0.23.0.min.js';
Future<void>? _loading;

/// Loads the bundled ZXing-js once. The relative URL resolves against the
/// app's base href; there is no CDN fallback.
Future<void> _loadZxing() => _loading ??= () {
  if (globalContext.has('ZXing')) return Future<void>.value();
  final done = Completer<void>();
  final s = web.HTMLScriptElement()..src = _scriptUrl;
  s.onload = ((web.Event _) => done.complete()).toJS;
  s.onerror = ((web.Event _) => done.completeError('zxing')).toJS;
  web.document.head!.append(s);
  return done.future;
}();

int _nextId = 0;

class QrCameraView extends StatefulWidget {
  const QrCameraView({super.key, required this.onText, required this.onError});
  final void Function(String text) onText;
  final void Function(QrCameraProblem problem) onError;
  @override
  State<QrCameraView> createState() => _QrCameraViewState();
}

class _QrCameraViewState extends State<QrCameraView> {
  late final String _viewType = 'otpanda-qr-video-${_nextId++}';
  final web.HTMLVideoElement _video = web.HTMLVideoElement();
  final web.HTMLCanvasElement _canvas = web.HTMLCanvasElement();
  web.MediaStream? _stream;
  Timer? _timer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _video
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => _video,
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _loadZxing();
      final constraints = web.MediaStreamConstraints(
        video: {'facingMode': 'environment'}.jsify()!,
        audio: false.toJS,
      );
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
      if (_disposed) {
        _stop(stream);
        return;
      }
      _stream = stream;
      _video.srcObject = stream;
      _timer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _scan(),
      );
    } catch (e) {
      final denied = e.toString().contains('NotAllowedError');
      widget.onError(
        denied ? QrCameraProblem.permissionDenied : QrCameraProblem.unavailable,
      );
    }
  }

  void _scan() {
    final w = _video.videoWidth, h = _video.videoHeight;
    if (w == 0 || h == 0 || _disposed) return;
    _canvas
      ..width = w
      ..height = h;
    final ctx = _canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(_video, 0, 0);
    try {
      final zx = globalContext['ZXing'] as JSObject;
      final source = (zx['HTMLCanvasElementLuminanceSource'] as JSFunction)
          .callAsConstructor<JSObject>(_canvas);
      final binarizer = (zx['HybridBinarizer'] as JSFunction)
          .callAsConstructor<JSObject>(source);
      final bitmap = (zx['BinaryBitmap'] as JSFunction)
          .callAsConstructor<JSObject>(binarizer);
      final reader = (zx['QRCodeReader'] as JSFunction)
          .callAsConstructor<JSObject>();
      final result = reader.callMethod<JSObject>('decode'.toJS, bitmap);
      final text = result.callMethod<JSString>('getText'.toJS).toDart;
      widget.onText(text);
    } catch (_) {
      // No code in this frame (ZXing throws NotFoundException).
    }
  }

  void _stop(web.MediaStream s) {
    final tracks = s.getTracks().toDart;
    for (final t in tracks) {
      t.stop();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    final s = _stream;
    if (s != null) _stop(s);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
