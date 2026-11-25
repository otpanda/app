// UNRUN on a device by its author. Needs an Android emulator/device and the
// local harness (api repo: tool/native-roundtrip-harness.mjs) reachable via
// `adb reverse tcp:8787 tcp:8787`. Run with tool/android-roundtrip.sh.
//
// Joins the real AndroidKeystore and the app's own NativeAuth to the real
// auth-only Worker and a real D1 (Miniflare). Synthetic account only
// (alex@example.test). The ONLY test doubles are the Custom Tab (stands in for
// the browser leg: it asks the harness to mint the exchange code for the PKCE
// challenge NativeAuth generated) and the in-memory device-id store.
// NativeAuth's apiOrigin is the production constant so redirect_uri is exactly
// what the server requires; every byte goes to the loopback harness through the
// injected JsonPost. Production transport code is unchanged.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_signing.dart';

import 'p256_verify.dart';

const _harness = String.fromEnvironment(
  'HARNESS',
  defaultValue: 'http://127.0.0.1:8787',
);
const _prodApi = 'https://otpanda-api.abrahammurciano.workers.dev';

class _MemStore implements NativeSecureStore {
  String? id;
  @override
  Future<String?> readDeviceId() async => id;
  @override
  Future<void> writeDeviceId(String v) async => id = v;
  @override
  Future<void> clear() async => id = null;
}

class _NoGoogle implements GoogleIdTokenSource {
  @override
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

Future<Map<String, dynamic>> _h(String method, String path, [Object? body]) async {
  final c = HttpClient();
  try {
    final r = await c.openUrl(method, Uri.parse('$_harness$path'));
    if (body != null) {
      r.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      r.add(utf8.encode(jsonEncode(body)));
    }
    final res = await r.close();
    final t = await res.transform(utf8.decoder).join();
    return {'status': res.statusCode, ...(jsonDecode(t) as Map<String, dynamic>)};
  } finally {
    c.close(force: true);
  }
}

/// Stands in for the Custom Tab only. The URL carries the challenge and state
/// NativeAuth made; the harness mints the code for that challenge, and the
/// result is the App Link NativeAuth's own parser must accept.
class _HarnessBrowser implements BrowserHandoff {
  int runs = 0;
  @override
  Future<Uri?> run(Uri url) async {
    runs++;
    final p = Uri.splitQueryString(url.fragment);
    final m = await _h('POST', '/__harness/mint', {'challenge': p['c']});
    expect(m['status'], 200, reason: 'harness refused to mint');
    return Uri.parse('$_prodApi/app-return#code=${Uri.encodeQueryComponent(m['code'] as String)}&state=${Uri.encodeQueryComponent(p['s']!)}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('real Keystore + NativeAuth -> mounted Worker/D1: sign-in, bearer reads, rename, renewal', () async {
    expect((await _h('GET', '/__harness/health'))['ok'], isTrue);
    final seed = await _h('POST', '/__harness/seed');
    expect(seed['status'], 200);
    final entryId = seed['entryId'] as String;

    final ks = AndroidKeystoreAdapter();
    await ks.deleteKey();
    final store = _MemStore();
    final browser = _HarnessBrowser();
    final auth = NativeAuth(
      post: androidJsonPost(_harness),
      keystore: ks,
      browser: browser,
      google: _NoGoogle(),
      store: store,
      apiOrigin: _prodApi,
      launchUrl: (c, s) => Uri.parse('https://harness.invalid/#c=${Uri.encodeQueryComponent(c)}&s=${Uri.encodeQueryComponent(s)}'),
    );

    // 1. Real sign-in. NativeAuth generates the Keystore pending key, the PKCE
    // pair and the state; the server exchanges the code and registers the key.
    final session = await auth.signInWithBrowser();
    expect(browser.runs, 1);
    expect(session.deviceId, isNotEmpty);
    expect(session.access, isNotEmpty);
    expect(store.id, session.deviceId);
    expect(await ks.hasPendingKey(), isFalse, reason: 'key committed after 200');

    // The server registered an android device session for this install.
    final devs = await _h('GET', '/__harness/devices');
    expect((devs['devices'] as List).any((d) => d['deviceId'] == session.deviceId && d['clientKind'] == 'android' && d['revoked'] == false), isTrue);

    // 2. Bearer reads over the app's own bearer transport.
    final bearer = androidBearerRequest(_harness);
    final entries = await bearer('GET', '/v1/manage/entries', bearer: session.access);
    expect(entries.status, 200);
    final list = (jsonDecode(entries.body) as Map)['entries'] as List;
    expect(list.any((e) => e['entry_id'] == entryId && e['label'] == 'Fictional service'), isTrue);
    final codes = await bearer('GET', '/v1/manage/active-codes', bearer: session.access);
    expect(codes.status, 200);
    expect(((jsonDecode(codes.body) as Map)['records'] as List).any((r) => r['entryId'] == entryId && r['code'] == '123456'), isTrue);

    // 3. Rename through the server, then read it back and check D1 directly.
    final rename = await bearer('POST', '/v1/manage/entry/rename',
        body: jsonEncode({'entryId': entryId, 'label': 'Renamed on device'}), bearer: session.access);
    expect(rename.status, 200);
    final after = await bearer('GET', '/v1/manage/entries', bearer: session.access);
    expect(((jsonDecode(after.body) as Map)['entries'] as List).any((e) => e['label'] == 'Renamed on device'), isTrue);
    expect((await _h('GET', '/__harness/entry?id=$entryId'))['label'], 'Renamed on device');

    // 4. Signed renewal: NativeAuth signs with the real Keystore key and the
    // server verifies against the key it registered at sign-in.
    final renewed = await auth.renew();
    expect(renewed, isNotNull);
    expect(renewed!.deviceId, session.deviceId);
    final again = await bearer('GET', '/v1/manage/session', bearer: renewed.access);
    expect(again.status, 200);

    // 5. Negative control: a real Keystore signature over a DIFFERENT message
    // is refused by the server, so the pass in step 4 is not vacuous.
    final post = androidJsonPost(_harness);
    final ch = await post('/auth/native/challenge', {'device_id': session.deviceId, 'purpose': 'renew'});
    expect(ch.status, 200);
    final nonce = ch.body!['nonce'] as String;
    final exp = ch.body!['expires_at'] as int;
    final good = nativeMessage(purpose: NativePurpose.renew, deviceId: session.deviceId, nonce: nonce, expiresAt: exp);
    final wrong = nativeMessage(purpose: NativePurpose.renew, deviceId: session.deviceId, nonce: nonce, expiresAt: exp + 1);
    final wrongSig = ecdsaDerToRaw(await ks.signDer(wrong));
    final refused = await post('/auth/native/renew', {
      'device_id': session.deviceId,
      'nonce': nonce,
      'expires_at': exp,
      'signature': base64UrlNoPad(wrongSig),
    });
    expect(refused.status, 401);

    // The Keystore key itself verifies the right message with the independent
    // P-256 verifier, tying the server result to the on-device key.
    final pub = await ks.ensureKey();
    final goodDer = await ks.signDer(good);
    expect(verifyP256Der(pub, good, goodDer), isTrue);
    expect(verifyP256Der(pub, wrong, goodDer), isFalse);

    // 6. Bad bearer is refused.
    expect((await bearer('GET', '/v1/manage/session', bearer: 'x' * 40)).status, 401);

    await ks.deleteKey();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
