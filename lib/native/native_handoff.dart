import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Browser handoff pieces for native sign-in: PKCE S256 and the App Link
/// return parser. Pure Dart, no platform channels.
class PkcePair {
  const PkcePair(this.verifier, this.challenge);
  final String verifier;
  final String challenge;

  static String _b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

  static String challengeFor(String verifier) =>
      _b64url(sha256.convert(ascii.encode(verifier)).bytes);

  factory PkcePair.generate([Random? random]) {
    final r = random ?? Random.secure();
    final v = _b64url(
      Uint8List.fromList(List.generate(32, (_) => r.nextInt(256))),
    );
    return PkcePair(v, challengeFor(v));
  }
}

String generateState([Random? random]) {
  final r = random ?? Random.secure();
  return PkcePair._b64url(List.generate(32, (_) => r.nextInt(256)));
}

class AppReturn {
  const AppReturn(this.code, this.state);
  final String code;
  final String state;
}

/// Parses the API app-return URL (code and state in the fragment). Returns null for any
/// other host, path, scheme, missing or duplicated fields, query-string
/// parameters (secrets only travel in the fragment), or state mismatch.
AppReturn? parseAppReturn(
  Uri uri, {
  required String apiOrigin,
  required String expectedState,
}) {
  final base = Uri.parse(apiOrigin);
  if (uri.scheme != 'https' || uri.host != base.host) return null;
  if (uri.userInfo.isNotEmpty || uri.hasPort && uri.port != 443) return null;
  if (uri.path != '/app-return' || uri.hasQuery) return null;
  if (!uri.hasFragment) return null;
  final Map<String, String> p;
  try {
    final pairs = uri.fragment.split('&');
    p = {};
    for (final kv in pairs) {
      final i = kv.indexOf('=');
      if (i <= 0) return null;
      final k = Uri.decodeQueryComponent(kv.substring(0, i));
      if (p.containsKey(k)) return null;
      p[k] = Uri.decodeQueryComponent(kv.substring(i + 1));
    }
  } on FormatException {
    return null;
  }
  final code = p['code'], state = p['state'];
  if (code == null || code.isEmpty || state == null || state.isEmpty) {
    return null;
  }
  if (state.length != expectedState.length) return null;
  var diff = 0;
  for (var i = 0; i < state.length; i++) {
    diff |= state.codeUnitAt(i) ^ expectedState.codeUnitAt(i);
  }
  return diff == 0 ? AppReturn(code, state) : null;
}

/// PROPOSED contract (not implemented server-side yet; primary owns the Pages
/// bridge): fragment-only native intent on the canonical app entry. No
/// redirect_uri is ever passed; the API approve destination is fixed there.
Uri pagesNativeLaunchUrl(
  String challenge,
  String state, {
  String appEntry = 'https://otpanda.github.io/app/',
}) {
  final re = RegExp(r'^[A-Za-z0-9_-]{43}$');
  if (!re.hasMatch(challenge) || !re.hasMatch(state)) {
    throw ArgumentError('challenge and state must be 43 base64url characters');
  }
  return Uri.parse('$appEntry#native=1&challenge=$challenge&state=$state');
}
