import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../session_contract.dart';
import 'native_auth.dart';
import 'native_bridge.dart';
import 'native_realtime.dart';

/// Android-only adapters. Never import from web code (uses dart:io).
const nativeChannel = MethodChannel('app.otpanda/native');
const googleChannel = MethodChannel('app.otpanda/google');

Future<T> _guard<T>(Future<T> Function() f) async {
  try {
    return await f();
  } on PlatformException {
    throw const NativeAuthException('keystore');
  } on MissingPluginException {
    throw const NativeAuthException('keystore');
  }
}

/// Best-effort device display label (user-set name, else model), 1..40 code
/// points, or null. Display metadata only, never an identity.
Future<String?> androidDeviceLabel({
  MethodChannel channel = nativeChannel,
}) async {
  try {
    return cappedDeviceLabel(await channel.invokeMethod<String>('deviceLabel'));
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

class AndroidKeystoreAdapter implements NativeKeystore {
  AndroidKeystoreAdapter({MethodChannel channel = nativeChannel})
    : _c = channel;
  final MethodChannel _c;

  @override
  Future<Uint8List> ensureKey() =>
      _guard(() async => (await _c.invokeMethod<Uint8List>('ensureKey'))!);
  @override
  Future<Uint8List> beginNewKey() =>
      _guard(() async => (await _c.invokeMethod<Uint8List>('beginNewKey'))!);
  @override
  Future<void> commitNewKey() =>
      _guard(() => _c.invokeMethod<void>('commitNewKey'));
  @override
  Future<void> discardNewKey() =>
      _guard(() => _c.invokeMethod<void>('discardNewKey'));
  @override
  Future<bool> hasPendingKey() =>
      _guard(() async => await _c.invokeMethod<bool>('hasPendingKey') ?? false);
  @override
  Future<Uint8List> signDer(Uint8List message, {bool pending = false}) =>
      _guard(
        () async => (await _c.invokeMethod<Uint8List>('sign', {
          'message': message,
          'pending': pending,
        }))!,
      );
  @override
  Future<void> deleteKey() => _guard(() => _c.invokeMethod<void>('deleteKey'));
}

/// Custom Tab (in-app browser view) out, verified App Link back.
///
/// A link can arrive by push (`appLink`, activity already running) or by
/// pull (`takeInitialLink`, kept natively until taken, which covers a late
/// engine or cold start). Returning to the app with no link inside [grace]
/// means the user closed the tab: that completes with null at once.
class CustomTabHandoff with WidgetsBindingObserver implements BrowserHandoff {
  CustomTabHandoff({
    MethodChannel channel = nativeChannel,
    this.grace = const Duration(seconds: 2),
    this.timeout = const Duration(minutes: 10),
    Future<bool> Function(Uri)? launch,
  }) : _c = channel,
       _launch =
           launch ?? ((u) => launchUrl(u, mode: LaunchMode.inAppBrowserView)) {
    _c.setMethodCallHandler((call) async {
      if (call.method == 'appLink' && call.arguments is String) {
        _finish(Uri.tryParse(call.arguments as String));
      }
    });
  }

  final MethodChannel _c;
  final Duration grace;
  final Duration timeout;
  final Future<bool> Function(Uri) _launch;
  Completer<Uri?>? _wait;
  Timer? _graceTimer, _deadline;
  bool _wentAway = false;

  void _finish(Uri? u) {
    _graceTimer?.cancel();
    _deadline?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete(u);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_wait == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wentAway = true;
    } else if (state == AppLifecycleState.resumed && _wentAway) {
      _graceTimer?.cancel();
      // Pull first: a link that arrived while Dart was paused is waiting natively.
      _c.invokeMethod<String>('takeInitialLink').then((l) {
        if (_wait == null) return;
        if (l != null) {
          _finish(Uri.tryParse(l));
        } else {
          _graceTimer = Timer(grace, () => _finish(null));
        }
      });
    }
  }

  @override
  Future<Uri?> run(Uri url) async {
    await _guard(
      () => _c.invokeMethod<String>('takeInitialLink'),
    ); // drop any stale link
    final c = _wait = Completer<Uri?>();
    _wentAway = false;
    WidgetsBinding.instance.addObserver(this);
    _deadline = Timer(timeout, () => _finish(null));
    var ok = false;
    try {
      ok = await _launch(url);
    } on PlatformException {
      ok = false;
    }
    if (!ok) _finish(null);
    return c.future;
  }
}

/// Google flavor: native ID token via Credential Manager. On F-Droid the
/// native side does not exist, [probe] stays false and the button is hidden.
class AndroidGoogleSource implements GoogleIdTokenSource {
  AndroidGoogleSource({
    MethodChannel channel = googleChannel,
    this.serverClientId = const String.fromEnvironment(
      'GOOGLE_SERVER_CLIENT_ID',
    ),
  }) : _c = channel;
  final MethodChannel _c;

  /// Public Web client ID, a build-time define. Empty hides native Google.
  final String serverClientId;
  bool _available = false;

  @override
  bool get available => _available;

  Future<void> probe() async {
    if (serverClientId.isEmpty) return;
    try {
      _available = await _c.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      _available = false;
    }
  }

  @override
  Future<String?> idToken({required String nonce}) async {
    try {
      return await _c.invokeMethod<String>('idToken', {
        'nonce': nonce,
        'serverClientId': serverClientId,
      });
    } on PlatformException {
      throw const NativeAuthException('unavailable');
    }
  }
}

/// JSON POST with no cookies and no Origin header (plain dart:io client).
/// One deadline covers connect, send and reading the whole body.
JsonPost androidJsonPost(
  String apiOrigin, {
  HttpClient? client,
  Duration deadline = const Duration(seconds: 20),
}) {
  final http = client ?? HttpClient();
  return (path, body) => () async {
    final req = await http.postUrl(Uri.parse('$apiOrigin$path'));
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    // /google/begin and /logout require a literally empty body.
    if (body.isNotEmpty) {
      // Exactly application/json: the server is strict (no charset).
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Map<String, dynamic>? parsed;
    if (text.isNotEmpty) {
      try {
        final j = jsonDecode(text);
        if (j is Map<String, dynamic>) parsed = j;
      } on FormatException {
        parsed = null;
      }
    }
    return (status: res.statusCode, body: parsed);
  }().timeout(deadline);
}

/// Bearer request for the shared account UI: no cookies, no Origin, no
/// redirects, bounded body, one deadline over connect, send and read.
BearerRequest androidBearerRequest(
  String apiOrigin, {
  HttpClient? client,
  Duration deadline = const Duration(seconds: 20),
  int maxBytes = 524288,
}) {
  final http = client ?? HttpClient();
  return (method, path, {body, query, required bearer}) => () async {
    final uri = Uri.parse('$apiOrigin$path')
        .replace(queryParameters: query?.isEmpty ?? true ? null : query);
    final req = await http.openUrl(method, uri);
    req.followRedirects = false;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      // Exactly application/json: the server is strict (no charset).
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(body));
    }
    final res = await req.close();
    final out = BytesBuilder(copy: false);
    await for (final chunk in res) {
      out.add(chunk);
      if (out.length > maxBytes) {
        throw const FormatException('response too large');
      }
    }
    return SessionResponse(
      res.statusCode,
      utf8.decode(out.takeBytes()),
      retryAfterSeconds: parseRetryAfter(res.headers.value('retry-after')),
    );
  }().timeout(deadline);
}

class _IoRealtimeSocket implements RealtimeSocket {
  _IoRealtimeSocket(this._ws)
    : messages = _ws
          .where((e) => e is String)
          .cast<String>()
          .asBroadcastStream();
  final WebSocket _ws;
  @override
  final Stream<String> messages;
  @override
  String? get protocol => _ws.protocol;
  @override
  int? get closeCode => _ws.closeCode;
  @override
  void close([int code = 1000]) {
    // Codes below 3000 other than 1000 are not allowed by dart:io.
    _ws.close(code == 1000 || code >= 3000 ? code : 1000);
  }
}

/// WebSocket to /auth/realtime. No Origin header is sent (dart:io adds none),
/// no cookies, no compression, and the ticket rides only in the subprotocol
/// list, never in the URL.
RealtimeConnector androidRealtimeConnector(
  String apiOrigin, {
  Duration pingInterval = const Duration(seconds: 25),
}) => ioRealtimeConnector(
  Uri.parse('$apiOrigin/auth/realtime').replace(scheme: 'wss'),
  pingInterval: pingInterval,
);

/// The transport behind [androidRealtimeConnector], with the URL injectable
/// for tests. [pingInterval] makes dart:io send WebSocket control-frame pings
/// (RFC 6455 opcode 0x9, not a data frame, so the server never sees an
/// application message) and close the socket when no pong comes back. That is
/// the only half-open detection; there is no polling. The server side must
/// answer control pings: unproven against the deployed edge.
RealtimeConnector ioRealtimeConnector(
  Uri uri, {
  Duration pingInterval = const Duration(seconds: 25),
}) => (protocols) async {
  final ws = await WebSocket.connect(
    uri.toString(),
    protocols: protocols,
    compression: CompressionOptions.compressionOff,
  );
  ws.pingInterval = pingInterval;
  return _IoRealtimeSocket(ws);
};

/// Retry-After as whole seconds: delta-seconds (digits only) or an HTTP-date
/// (IMF-fixdate, RFC 850 or asctime). A past date, junk or no header is null.
/// Callers still bound the result.
int? parseRetryAfter(String? value, {DateTime Function()? now}) {
  final v = value?.trim();
  if (v == null || v.isEmpty || v.length > 64) return null;
  if (RegExp(r'^[0-9]{1,6}$').hasMatch(v)) return int.parse(v);
  try {
    var at = HttpDate.parse(v);
    final cur = (now ?? DateTime.now)().toUtc();
    // RFC 850 has a two-digit year that dart:io leaves as 00yy. RFC 9110: a
    // date more than 50 years ahead is read as the past century.
    if (at.year < 100) {
      var y = at.year + (cur.year ~/ 100) * 100;
      if (y > cur.year + 50) {
        y -= 100;
      }
      at = DateTime.utc(y, at.month, at.day, at.hour, at.minute, at.second);
    }
    final secs = at.difference(cur).inSeconds;
    return secs > 0 ? secs : null;
  } catch (_) {
    return null;
  }
}
