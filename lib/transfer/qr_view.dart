import 'package:material_ui/material_ui.dart';
import 'package:zxing2/qrcode.dart';

/// Draws a QR for [text] in black on white with a quiet zone. Local only.
class QrView extends StatelessWidget {
  const QrView(this.text, {super.key, this.size = 280});
  final String text;
  final double size;
  @override
  Widget build(BuildContext context) {
    final m = Encoder.encode(text, ErrorCorrectionLevel.l).matrix!;
    final w = m.width;
    final dark = [
      for (var y = 0; y < m.height; y++)
        for (var x = 0; x < w; x++) m.get(x, y) == 1,
    ];
    return Semantics(
      label: 'QR code',
      child: CustomPaint(size: Size.square(size), painter: _QrPainter(w, dark)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.width, this.dark);
  final int width;
  final List<bool> dark;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    const quiet = 4;
    final cell = size.width / (width + quiet * 2);
    final p = Paint()..color = Colors.black;
    for (var i = 0; i < dark.length; i++) {
      if (dark[i]) {
        canvas.drawRect(
          Rect.fromLTWH(
            (i % width + quiet) * cell,
            (i ~/ width + quiet) * cell,
            cell + 0.5,
            cell + 0.5,
          ),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.dark != dark;
}
