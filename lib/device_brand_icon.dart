import 'package:material_ui/material_ui.dart';

import 'brand_icon_paths.dart';
import 'recovery_contract.dart';

/// The closed set of marks the device list can show. Anything else gets a
/// generic icon, so no unvetted text ever picks an asset.
enum DeviceBrand {
  chrome,
  firefox,
  safari,
  edge,
  opera,
  brave,
  windows,
  apple,
  android,
  linux,
}

/// Exact, case-insensitive match against the closed set and a few common
/// spellings. Not a substring search. Unknown or missing is null.
DeviceBrand? deviceBrandFor(String? label) {
  if (label == null) return null;
  const aliases = <String, DeviceBrand>{
    'chrome': DeviceBrand.chrome,
    'google chrome': DeviceBrand.chrome,
    'chromium': DeviceBrand.chrome,
    'firefox': DeviceBrand.firefox,
    'mozilla firefox': DeviceBrand.firefox,
    'safari': DeviceBrand.safari,
    'mobile safari': DeviceBrand.safari,
    'edge': DeviceBrand.edge,
    'microsoft edge': DeviceBrand.edge,
    'opera': DeviceBrand.opera,
    'brave': DeviceBrand.brave,
    'windows': DeviceBrand.windows,
    'mac': DeviceBrand.apple,
    'macos': DeviceBrand.apple,
    'mac os': DeviceBrand.apple,
    'ios': DeviceBrand.apple,
    'ipados': DeviceBrand.apple,
    'apple': DeviceBrand.apple,
    'android': DeviceBrand.android,
    'linux': DeviceBrand.linux,
  };
  return aliases[label.trim().toLowerCase()];
}

/// Native is Android. A web session shows its browser's mark, else its OS's.
DeviceBrand? deviceBrandOf(RecoverySession d) {
  if (d.clientKind == 'android') return DeviceBrand.android;
  return deviceBrandFor(d.browser) ?? deviceBrandFor(d.os);
}

/// Parses an SVG path 'd' string (M L H V C S A Z, absolute and relative,
/// including packed arc flags) into a Flutter [Path]. Returns an empty path
/// on anything it does not understand.
Path parseSvgPath(String d) {
  final path = Path();
  final tok = RegExp(r'[a-zA-Z]|-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?');
  final src = d;
  String? cmd;
  double x = 0, y = 0, sx = 0, sy = 0, cx = 0, cy = 0;
  var prev = '';
  int pos = 0;
  // Arc flags can be packed ("011"), so numbers are read on demand.
  double? num_({bool flag = false}) {
    while (pos < src.length && (src[pos] == ' ' || src[pos] == ',')) {
      pos++;
    }
    if (pos >= src.length) return null;
    if (flag) {
      final c = src[pos];
      if (c != '0' && c != '1') return null;
      pos++;
      return c == '1' ? 1 : 0;
    }
    final m = tok.matchAsPrefix(src, pos);
    if (m == null) return null;
    final t = m.group(0)!;
    if (RegExp(r'^[a-zA-Z]$').hasMatch(t)) return null;
    pos = m.end;
    return double.tryParse(t);
  }

  bool more() {
    while (pos < src.length && (src[pos] == ' ' || src[pos] == ',')) {
      pos++;
    }
    if (pos >= src.length) return false;
    return !RegExp(r'[a-zA-Z]').hasMatch(src[pos]);
  }

  while (true) {
    while (pos < src.length && (src[pos] == ' ' || src[pos] == ',')) {
      pos++;
    }
    if (pos >= src.length) break;
    if (RegExp(r'[a-zA-Z]').hasMatch(src[pos])) {
      cmd = src[pos++];
      if (cmd == 'z' || cmd == 'Z') {
        path.close();
        x = sx;
        y = sy;
        prev = 'z';
        continue;
      }
    } else if (cmd == null) {
      return Path();
    }
    final c = cmd;
    final rel = c == c.toLowerCase();
    final u = c.toUpperCase();
    do {
      switch (u) {
        case 'M':
          final a = num_(), b = num_();
          if (a == null || b == null) return Path();
          x = rel ? x + a : a;
          y = rel ? y + b : b;
          path.moveTo(x, y);
          sx = x;
          sy = y;
          cmd = rel ? 'l' : 'L';
          prev = 'M';
        case 'L':
          final a = num_(), b = num_();
          if (a == null || b == null) return Path();
          x = rel ? x + a : a;
          y = rel ? y + b : b;
          path.lineTo(x, y);
          prev = 'L';
        case 'H':
          final a = num_();
          if (a == null) return Path();
          x = rel ? x + a : a;
          path.lineTo(x, y);
          prev = 'H';
        case 'V':
          final a = num_();
          if (a == null) return Path();
          y = rel ? y + a : a;
          path.lineTo(x, y);
          prev = 'V';
        case 'C':
          final v = [for (var k = 0; k < 6; k++) num_()];
          if (v.contains(null)) return Path();
          final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
          final x1 = ox + v[0]!, y1 = oy + v[1]!;
          cx = ox + v[2]!;
          cy = oy + v[3]!;
          x = ox + v[4]!;
          y = oy + v[5]!;
          path.cubicTo(x1, y1, cx, cy, x, y);
          prev = 'C';
        case 'S':
          final v = [for (var k = 0; k < 4; k++) num_()];
          if (v.contains(null)) return Path();
          final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
          final x1 = (prev == 'C' || prev == 'S') ? 2 * x - cx : x;
          final y1 = (prev == 'C' || prev == 'S') ? 2 * y - cy : y;
          cx = ox + v[0]!;
          cy = oy + v[1]!;
          x = ox + v[2]!;
          y = oy + v[3]!;
          path.cubicTo(x1, y1, cx, cy, x, y);
          prev = 'S';
        case 'A':
          final rx = num_(), ry = num_(), rot = num_();
          final large = num_(flag: true), sweep = num_(flag: true);
          final a = num_(), b = num_();
          if ([rx, ry, rot, large, sweep, a, b].contains(null)) return Path();
          x = rel ? x + a! : a!;
          y = rel ? y + b! : b!;
          path.arcToPoint(
            Offset(x, y),
            radius: Radius.elliptical(rx!, ry!),
            rotation: rot!,
            largeArc: large == 1,
            clockwise: sweep == 1,
          );
          prev = 'A';
        default:
          return Path();
      }
    } while (more());
  }
  return path;
}

class _BrandPainter extends CustomPainter {
  final Path path;
  final double w, h;
  final Color color;
  _BrandPainter(this.path, this.w, this.h, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / (w > h ? w : h);
    canvas.translate((size.width - w * s) / 2, (size.height - h * s) / 2);
    canvas.scale(s);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BrandPainter o) => o.color != color || o.path != path;
}

final _cache = <DeviceBrand, Path>{};

/// A brand mark, or the generic [fallback] icon when [brand] is null.
class DeviceBrandIcon extends StatelessWidget {
  final DeviceBrand? brand;
  final IconData fallback;
  final double size;
  const DeviceBrandIcon({
    super.key,
    required this.brand,
    this.fallback = Icons.devices_outlined,
    this.size = 24,
  });
  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ??
        (Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFFB8CBC0)
            : const Color(0xFF444444));
    final b = brand;
    final spec = b == null ? null : brandIconPaths[b.name];
    if (b == null || spec == null) return Icon(fallback, size: size);
    final path = _cache.putIfAbsent(b, () => parseSvgPath(spec.$3));
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _BrandPainter(path, spec.$1, spec.$2, color),
        ),
      ),
    );
  }
}
