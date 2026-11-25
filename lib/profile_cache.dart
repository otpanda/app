import 'dart:convert';

import 'profile_header.dart' show isGooglePicture;

/// Static identity cached for one sign-in: email and a Google picture address.
/// Never holds passkey or Google status, codes, tokens or anything that can
/// change what the account may do. The bridge owns storage and wipes it with
/// the session; reads need both the owner id and the per-sign-in session id.
abstract interface class ProfileCacheBridge {
  /// Returns the cached JSON or an empty string. Mismatch, malformed data, no
  /// session or a missing flag all give an empty string.
  String profileRead(String ownerId, String sessionId);
  void profileWrite(
    String ownerId,
    String sessionId,
    String email,
    String? picture,
  );
  void profileClear();

  /// True once another tab ended this sign-in; the bridge then refuses reads
  /// and writes and the page must stop showing the cached identity.
  bool get profileRevoked;

  /// Calls [listener] when this tab's cache is revoked by another tab.
  void onProfileRevoked(void Function() listener);
}

final class CachedProfile {
  final String email;
  final String? picture;
  final int savedAt;
  const CachedProfile(this.email, this.picture, this.savedAt);

  /// A cached copy older than a day is shown but refreshed in the background.
  static const refreshAfterMs = 24 * 3600 * 1000;
  bool isFresh(int nowMs) =>
      nowMs >= savedAt && nowMs - savedAt < refreshAfterMs;
}

final sessionIdPattern = RegExp(r'^[0-9a-f]{64}$');

CachedProfile? parseCachedProfile(String raw) {
  if (raw.isEmpty || raw.length > 4096) return null;
  try {
    final v = jsonDecode(raw);
    if (v is! Map<String, dynamic>) return null;
    final email = v['email'], picture = v['picture'], at = v['savedAt'];
    final keys = v.keys.toSet();
    if (!(keys.length == 2 && keys.containsAll({'email', 'savedAt'}) ||
        keys.length == 3 &&
            keys.containsAll({'email', 'picture', 'savedAt'}))) {
      return null;
    }
    if (email is! String || email.isEmpty || email.length > 254) return null;
    if (at is! int || at < 0) return null;
    if (picture != null && !isGooglePicture(picture)) return null;
    return CachedProfile(email, picture as String?, at);
  } catch (_) {
    return null;
  }
}
