import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// Decodes a QR code from a luminance (Y) plane. [rowStride] may be larger
/// than [width] (camera planes are padded). Returns null when no code is
/// found. Pure Dart, no platform services.
String? decodeQrLuma(Uint8List y, int rowStride, int width, int height) {
  if (width <= 0 || height <= 0 || rowStride < width) return null;
  if (y.length < rowStride * (height - 1) + width) return null;
  try {
    final argb = Int32List(width * height);
    for (var row = 0; row < height; row++) {
      final from = row * rowStride, to = row * width;
      for (var x = 0; x < width; x++) {
        final v = y[from + x];
        argb[to + x] = 0xff000000 | (v << 16) | (v << 8) | v;
      }
    }
    final source = RGBLuminanceSource(width, height, argb);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    return QRCodeReader()
        .decode(bitmap, hints: DecodeHints()..put(DecodeHintType.tryHarder))
        .text;
  } on ReaderException {
    return null;
  } on ArgumentError {
    return null;
  }
}
