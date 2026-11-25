import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'main.dart' show avatarTint, ink, line;

/// SHA-256 of [input] as lowercase hex. Small and dependency free: it only
/// builds the Gravatar address.
String sha256Hex(String input) {
  const k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final bytes = utf8.encode(input);
  final bitLength = bytes.length * 8;
  final padded = <int>[...bytes, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLength >> (i * 8)) & 0xff);
  }
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;
  for (var o = 0; o < padded.length; o += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] =
          (padded[o + i * 4] << 24) |
          (padded[o + i * 4 + 1] << 16) |
          (padded[o + i * 4 + 2] << 8) |
          padded[o + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + k[i] + w[i]) & 0xffffffff;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}

/// Gravatar address for an email. `d=404` makes a missing picture an error
/// so the initials circle stays instead of Gravatar's default image.
String gravatarUrl(String email, {int size = 160}) =>
    'https://gravatar.com/avatar/${sha256Hex(email.trim().toLowerCase())}?s=$size&d=404';

/// Only Google's own picture hosts are used for a provider picture.
bool isGooglePicture(Object? url) {
  if (url is! String || url.length > 512) return false;
  final u = Uri.tryParse(url);
  return u != null &&
      u.scheme == 'https' &&
      u.userInfo.isEmpty &&
      (u.host == 'googleusercontent.com' ||
          u.host.endsWith('.googleusercontent.com'));
}

/// Up to two initials from the part of the email before the "@".
String initialsFor(String email) {
  final local = email.split('@').first;
  final parts = local
      .split(RegExp(r'[._\-+\s]+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  String first(String s) => String.fromCharCodes(s.runes.take(1)).toUpperCase();
  if (parts.length == 1) {
    return String.fromCharCodes(parts.first.runes.take(2)).toUpperCase();
  }
  return first(parts[0]) + first(parts[1]);
}

const profileAvatarSize = 80.0;

/// A coloured circle with initials, covered by the profile picture once it
/// has loaded: the Google picture first, then Gravatar. Any failure leaves
/// the initials.
class ProfileAvatar extends StatefulWidget {
  final String email;
  final String? googlePicture;
  final double size;
  final bool allowGravatar;
  const ProfileAvatar({
    super.key,
    required this.email,
    this.googlePicture,
    this.size = profileAvatarSize,
    this.allowGravatar = true,
  });
  @override
  State<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<ProfileAvatar> {
  int failed = 0;

  List<String> get sources => [
    if (isGooglePicture(widget.googlePicture)) widget.googlePicture!,
    if (widget.allowGravatar) gravatarUrl(widget.email),
  ];

  @override
  void didUpdateWidget(ProfileAvatar old) {
    super.didUpdateWidget(old);
    if (old.email != widget.email ||
        old.googlePicture != widget.googlePicture ||
        old.allowGravatar != widget.allowGravatar) {
      failed = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = sources;
    return ExcludeSemantics(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: ClipOval(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: avatarTint(widget.email),
                child: Center(
                  child: Text(
                    initialsFor(widget.email),
                    style: TextStyle(
                      fontFamily: 'BricolageGrotesque',
                      fontSize: widget.size * .375,
                      fontWeight: FontWeight.w800,
                      color: ink,
                    ),
                  ),
                ),
              ),
              if (failed < list.length)
                Image.network(
                  list[failed],
                  key: ValueKey(list[failed]),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  frameBuilder: (context, child, frame, sync) =>
                      AnimatedOpacity(
                        opacity: frame == null && !sync ? 0 : 1,
                        duration: const Duration(milliseconds: 180),
                        child: child,
                      ),
                  errorBuilder: (context, error, stack) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && failed < list.length) {
                        setState(() => failed++);
                      }
                    });
                    return const SizedBox.shrink();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Centred picture and email at the top of settings. While the account loads
/// it holds the same space with a grey circle and a bar, so nothing moves.
class ProfileHeader extends StatelessWidget {
  final String? email;
  final String? googlePicture;
  const ProfileHeader({super.key, required this.email, this.googlePicture});

  static const _barSample = 'person@example.com';

  @override
  Widget build(BuildContext context) {
    final loaded = email;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 20),
      child: Column(
        children: [
          if (loaded == null)
            const ExcludeSemantics(
              child: SizedBox(
                width: profileAvatarSize,
                height: profileAvatarSize,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: line,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            )
          else
            ProfileAvatar(email: loaded, googlePicture: googlePicture),
          const SizedBox(height: 12),
          if (loaded == null)
            const RedactedBar(_barSample)
          else
            Text(
              loaded,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
        ],
      ),
    );
  }
}

/// Redacted stand-in for the email, same size as the real text.
class RedactedBar extends StatelessWidget {
  final String sample;
  const RedactedBar(this.sample, {super.key});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Text(
      sample,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Colors.transparent,
        backgroundColor: line,
      ),
    ),
  );
}
