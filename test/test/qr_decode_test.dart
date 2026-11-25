import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:otpanda_client/otpauth.dart';
import 'package:otpanda_client/qr_decode.dart';

void main() {
  // Fixture: a real QR rendering of a valid otpauth URI, 640x480.
  final png = img.decodePng(
    base64Decode(File('test/fixtures/qr-otpauth.png.b64').readAsStringSync().trim()),
  )!;
  Uint8List luma(int stride) {
    final out = Uint8List(stride * png.height);
    for (var y = 0; y < png.height; y++) {
      for (var x = 0; x < png.width; x++) {
        final p = png.getPixel(x, y);
        out[y * stride + x] = p.luminance.round().clamp(0, 255).toInt();
      }
    }
    return out;
  }

  test('decodes a camera-style Y plane and the result parses', () {
    final text = decodeQrLuma(
      luma(png.width),
      png.width,
      png.width,
      png.height,
    );
    expect(text, startsWith('otpauth://totp/'));
    expect(parseOtpauth(text!).name, 'Example Co');
  });

  test('handles padded rows (stride larger than width)', () {
    final text = decodeQrLuma(
      luma(png.width + 32),
      png.width + 32,
      png.width,
      png.height,
    );
    expect(text, startsWith('otpauth://totp/'));
  });

  test('blank or invalid frames return null', () {
    expect(
      decodeQrLuma(
        Uint8List(640 * 480)..fillRange(0, 640 * 480, 255),
        640,
        640,
        480,
      ),
      isNull,
    );
    expect(decodeQrLuma(Uint8List(10), 640, 640, 480), isNull);
    expect(decodeQrLuma(Uint8List(10), 5, 10, 10), isNull);
  });
}
