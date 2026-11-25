import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/android_adapters.dart';

// No TestWidgetsFlutterBinding here: it would stub every HttpClient to 400.
void main() {
  test(
    'json post: no Origin or Cookie, empty body for {}, stalled body times out',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      final seen = <Map<String, Object?>>[];
      server.listen((r) async {
        final body = await utf8.decodeStream(r);
        seen.add({
          'path': r.uri.path,
          'origin': r.headers.value('origin'),
          'cookie': r.headers.value('cookie'),
          'ct': r.headers.value('content-type'),
          'body': body,
        });
        if (r.uri.path == '/stall') {
          r.response.headers.contentType = ContentType.json;
          r.response.write('{"a":');
          await r.response.flush(); // headers sent, body never finishes
        } else {
          r.response.headers.contentType = ContentType.json;
          r.response.write('{"nonce":"N"}');
          await r.response.close();
        }
      });
      final post = androidJsonPost(
        'http://127.0.0.1:${server.port}',
        deadline: const Duration(milliseconds: 400),
      );
      final ok = await post('/empty', const {});
      expect(ok.status, 200);
      expect(ok.body, {'nonce': 'N'});
      await post('/full', {'k': 'v'});
      expect(seen[0]['body'], '');
      expect(seen[1]['body'], '{"k":"v"}');
      expect(seen[1]['ct'], 'application/json');
      for (final s in seen) {
        expect(s['origin'], isNull);
        expect(s['cookie'], isNull);
      }
      await expectLater(
        post('/stall', const {}),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test(
    'bearer request sends exactly application/json for a body, none without',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      final seen = <String?>[];
      server.listen((r) async {
        await utf8.decodeStream(r);
        seen.add(r.headers.value('content-type'));
        r.response.headers.contentType = ContentType.json;
        r.response.write('{}');
        await r.response.close();
      });
      final req = androidBearerRequest('http://127.0.0.1:${server.port}');
      await req('POST', '/v1/manage/x', body: '{"a":1}', bearer: 'b');
      await req('GET', '/v1/manage/x', bearer: 'b');
      expect(seen, ['application/json', null]);
    },
  );
}
