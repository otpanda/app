import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_auth.dart' show BrowserHandoff;
import 'package:otpanda_client/native/native_google_link.dart';
import 'package:otpanda_client/native/native_handoff.dart';
import 'package:otpanda_client/native/native_manage_settings.dart';
import 'package:otpanda_client/native/native_passkey.dart';

String _tok(String c) => 'otpda_${c * 55}';
final _state = 'S' * 43;

class _Br implements BrowserHandoff {
  _Br(this.reply);
  Uri? Function(Uri)? reply;
  final urls = <Uri>[];
  @override
  Future<Uri?> run(Uri u) async {
    urls.add(u);
    return reply?.call(u);
  }
}

class _Pk implements PasskeyAssertionSource {
  _Pk(this.out);
  String? out;
  int calls = 0;
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async {
    calls++;
    return out;
  }
}

const _asserted =
    '{"id":"i","rawId":"i","type":"public-key","response":{"clientDataJSON":"c","authenticatorData":"a","signature":"s","userHandle":null}}';

void main() {
  late int now;
  Uri back({
    String state = '',
    Map<String, dynamic>? g,
    String path = '/app-return',
    String host = 'api.example',
    String extra = '',
  }) {
    final gg =
        g ??
        {
          'email': 'a@b.co',
          'expiresAt': now + 300000,
          'kind': 'link-only',
          'token': _tok('K'),
        };
    return Uri.parse(
      'https://$host$path${extra.isEmpty ? '' : '?$extra'}#google=${Uri.encodeQueryComponent(jsonEncode(gg))}&state=${state.isEmpty ? _state : state}',
    );
  }

  setUp(() => now = DateTime.now().millisecondsSinceEpoch);

  GoogleLinkReturn? parse(Uri u) => parseGoogleLinkReturn(
    u,
    expectedState: _state,
    nowMs: now,
    origin: 'https://api.example',
  );

  group('parseGoogleLinkReturn', () {
    test('the old Pages /app/ return and the real API host defaults', () {
      expect(parse(back(host: 'otpanda.github.io', path: '/app/')), isNull);
      final real = Uri.parse(
        'https://otpanda-api.abrahammurciano.workers.dev/app-return#google=${Uri.encodeQueryComponent(jsonEncode({'email': 'a@b.co', 'expiresAt': now + 300000, 'kind': 'link-only', 'token': _tok('K')}))}&state=$_state',
      );
      expect(
        parseGoogleLinkReturn(real, expectedState: _state, nowMs: now),
        isNotNull,
      );
    });

    for (final k in ['mismatch', 'restart']) {
      test('a link=$k return is no link', () {
        expect(
          parse(
            Uri.parse('https://api.example/app-return#link=$k&state=$_state'),
          ),
          isNull,
        );
      });
    }

    test('accepts the exact link-only fragment', () {
      final r = parse(back());
      expect(r!.token, _tok('K'));
      expect(r.email, 'a@b.co');
    });
    test('rejects other host, path, query, state, kind, keys, expiry', () {
      expect(parse(back(host: 'evil.example')), isNull);
      expect(parse(back(path: '/other')), isNull);
      expect(parse(back(extra: 'x=1')), isNull);
      expect(parse(back(state: 'X' * 43)), isNull);
      expect(
        parse(
          back(
            g: {
              'email': 'a@b.co',
              'expiresAt': now + 1000,
              'kind': 'link',
              'token': _tok('K'),
            },
          ),
        ),
        isNull,
      );
      expect(
        parse(
          back(
            g: {
              'email': 'a@b.co',
              'expiresAt': now + 1000,
              'kind': 'link-only',
              'token': _tok('K'),
              'x': 1,
            },
          ),
        ),
        isNull,
      );
      expect(
        parse(
          back(
            g: {
              'email': 'a@b.co',
              'expiresAt': now - 1,
              'kind': 'link-only',
              'token': _tok('K'),
            },
          ),
        ),
        isNull,
      );
      expect(
        parse(
          back(
            g: {
              'email': 'a@b.co',
              'expiresAt': now + 700000,
              'kind': 'link-only',
              'token': _tok('K'),
            },
          ),
        ),
        isNull,
      );
      expect(
        parse(
          back(
            g: {
              'email': 'a@b.co',
              'expiresAt': now + 1000,
              'kind': 'link-only',
              'token': 'short',
            },
          ),
        ),
        isNull,
      );
      expect(
        parse(
          Uri.parse('http://api.example/app-return#google={}&state=$_state'),
        ),
        isNull,
      );
    });
  });

  group('NativeGoogleConnect', () {
    late List<(String, String, Map<String, dynamic>?)> sent;
    late Map<String, ({int status, Map<String, dynamic>? body})> replies;
    late _Pk pk;
    late _Br br;

    NativeGoogleConnect make() => NativeGoogleConnect(
      settings: NativeManageSettings(
        request: (m, p, b) async {
          sent.add((m, p, b));
          final r = replies[p];
          if (r == null) throw Exception('network');
          return r;
        },
        passkeys: pk,
        nowMs: () => now,
      ),
      browser: br,
      apiOrigin: 'https://api.example',
      nowMs: () => now,
      newState: () => _state,
    );

    setUp(() {
      sent = [];
      pk = _Pk(_asserted);
      br = _Br((u) => back());
      replies = {
        '/v1/manage/google/link/ticket': (
          status: 200,
          body: {'ticket': 'T' * 43, 'expiresAt': now + 1000},
        ),
        '/v1/manage/google/link/begin': (
          status: 200,
          body: {
            'token': _tok('B'),
            'expires_at': now + 100000,
            'options': {
              'rpId': 'otpanda.github.io',
              'userVerification': 'required',
              'challenge': 'A' * 43,
              'allowCredentials': [
                {'id': 'c1'},
              ],
            },
          },
        ),
        '/v1/manage/google/link/finish': (
          status: 200,
          body: {'status': 'linked'},
        ),
      };
    });

    test('ticket, browser, passkey, link: connected', () async {
      final c = make();
      expect(await c.connect(), 'completed');
      expect(c.takeResult(), 'connected');
      expect(c.takeResult(), '');
      expect(sent[0].$3, {'state': _state});
      expect(
        br.urls.single.toString(),
        'https://api.example/auth/google/link/start?ticket=${'T' * 43}',
      );
      expect(sent[1].$3, {'continuation': _tok('K')});
      expect(sent[2].$3!['continuation'], _tok('K'));
      expect(sent[2].$3!['token'], _tok('B'));
      expect(pk.calls, 1);
    });

    test('ticket refusals map to the web reason codes', () async {
      for (final (st, err, want) in [
        (409, 'already_linked', 'already_linked'),
        (409, 'no_passkey', 'no_passkey'),
        (429, null, 'retry'),
        (401, null, 'signin'),
        (403, null, 'signin'),
        (500, null, 'unavailable'),
      ]) {
        replies['/v1/manage/google/link/ticket'] = (
          status: st,
          body: err == null ? {} : {'error': err},
        );
        expect(await make().connect(), want);
      }
      replies.remove('/v1/manage/google/link/ticket');
      expect(await make().connect(), 'unavailable');
      expect(br.urls, isEmpty);
    });

    test('closed browser is cancelled; a bad return is restart; neither asks for a passkey', () async {
      br.reply = (_) => null;
      var c = make();
      expect(await c.connect(), 'completed');
      expect(c.takeResult(), 'cancelled');
      br.reply = (_) => back(state: 'X' * 43);
      c = make();
      expect(await c.connect(), 'completed');
      expect(c.takeResult(), 'restart');
      expect(pk.calls, 0);
      expect(sent.any((e) => e.$2.endsWith('link/begin')), isFalse);
    });

    test('a dismissed prompt is cancelled and never finishes', () async {
      pk.out = null;
      final c = make();
      expect(await c.connect(), 'completed');
      expect(c.takeResult(), 'cancelled');
      expect(sent.any((e) => e.$2.endsWith('link/finish')), isFalse);
    });

    test('finish refusal is restart; unreadable outcome defers to the live overview', () async {
      replies['/v1/manage/google/link/finish'] = (status: 403, body: {});
      var c = make();
      await c.connect();
      expect(c.takeResult(), 'restart');
      replies['/v1/manage/google/link/finish'] = (status: 503, body: null);
      c = make();
      await c.connect();
      expect(c.takeResult(), 'unconfirmed');
    });

    test('a return that took longer than 10 minutes is restart', () async {
      br.reply = (_) {
        now += 601000;
        return back(
          g: {
            'email': 'a@b.co',
            'expiresAt': now + 300000,
            'kind': 'link-only',
            'token': _tok('K'),
          },
        );
      };
      final c = make();
      await c.connect();
      expect(c.takeResult(), 'restart');
      expect(pk.calls, 0);
    });
  });
}
