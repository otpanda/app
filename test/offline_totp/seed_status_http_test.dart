import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/seed_status_http.dart';

class Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  set contentType(ContentType? value) {
    set('content-type', value!);
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Reply extends Stream<List<int>> implements HttpClientResponse {
  Reply(this.parts, {this.statusCode = 200});
  final List<List<int>> parts;
  @override
  final int statusCode;
  @override
  final headers = Headers();
  int delivered = 0;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable(
        parts.map((p) {
          delivered++;
          return p;
        }),
      ).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Request implements HttpClientRequest {
  Request(this.reply);
  final Reply reply;
  @override
  final headers = Headers();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  void write(Object? value) {}
  @override
  Future<HttpClientResponse> close() async => reply;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Client implements HttpClient {
  Client(this.request);
  final Request request;
  Uri? url;
  bool closed = false, stall = false;
  @override
  Duration? connectionTimeout;
  @override
  set findProxy(String Function(Uri)? f) {}
  @override
  Future<HttpClientRequest> postUrl(Uri u) async {
    url = u;
    if (stall) return Completer<HttpClientRequest>().future;
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = force;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Override extends HttpOverrides {
  Override(this.client);
  final Client client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

void main() {
  test(
    'fresh credential-free HTTPS request, no redirect, honors Retry-After',
    () async {
      final reply = Reply([utf8.encode('{"state":"active"}')])
        ..headers.set('retry-after', '120');
      final request = Request(reply), client = Client(Request(reply));
      final result = await HttpOverrides.runWithHttpOverrides(
        () => SeedStatusHttp().post('/v1/manage/seed-sync/status-finish', {
          'token': 'synthetic',
          'signature': 'synthetic',
        }),
        Override(client),
      );
      expect(result.retryAfter, const Duration(minutes: 2));
      expect(client.url!.scheme, 'https');
      expect(
        (client.request.headers as Headers).values.keys,
        unorderedEquals(['content-type', 'accept']),
      );
      for (final name in ['authorization', 'cookie', 'origin']) {
        expect(
          (client.request.headers as Headers).values.containsKey(name),
          false,
        );
      }
      expect(client.request.followRedirects, false);
      expect(client.closed, true);
      expect((request.headers as Headers).values, isEmpty);
    },
  );
  test(
    'explicit loopback origin keeps status separate and credential-free',
    () async {
      final c = Client(Request(Reply([utf8.encode('{}')])));
      await HttpOverrides.runWithHttpOverrides(
        () => SeedStatusHttp(origin: 'http://127.0.0.1:8787')
            .post('/v1/manage/seed-sync/status-begin', {'keyId': 'synthetic'}),
        Override(c),
      );
      expect(
        c.url,
        Uri.parse('http://127.0.0.1:8787/v1/manage/seed-sync/status-begin'),
      );
      expect(
        (c.request.headers as Headers).values.keys,
        unorderedEquals(['content-type', 'accept']),
      );
      expect(c.request.followRedirects, false);
      expect(c.closed, true);
      for (final origin in [
        'http://example.test',
        'https://user:password@example.test',
        'https://example.test/path',
        'https://example.test?x=1',
        'https://example.test#x',
        'file:///x',
      ]) {
        expect(() => SeedStatusHttp(origin: origin), throwsArgumentError);
      }
    },
  );
  test('Retry-After hour boundary and future date are bounded', () async {
    for (final value in [
      '3600',
      '172800',
      HttpDate.format(DateTime.now().add(const Duration(days: 1))),
    ]) {
      final r = Reply([])..headers.set('retry-after', value);
      final c = Client(Request(r));
      final result = await HttpOverrides.runWithHttpOverrides(
        () => SeedStatusHttp().post('/v1/manage/seed-sync/status-begin', {
          'keyId': 'synthetic',
        }),
        Override(c),
      );
      expect(result.retryAfter, const Duration(hours: 1), reason: value);
    }
  });
  test('oversized stream stops before later chunks, force closes', () async {
    final r = Reply([
          List.filled(3000, 65),
          List.filled(2000, 65),
          [66],
        ]),
        c = Client(Request(Reply([])));
    final client = Client(Request(r));
    await expectLater(
      HttpOverrides.runWithHttpOverrides(
        () => SeedStatusHttp().post('/v1/manage/seed-sync/status-begin', {
          'keyId': 'key',
        }),
        Override(client),
      ),
      throwsFormatException,
    );
    expect(r.delivered, 2);
    expect(client.closed, true);
    expect(c.closed, false);
  });
  test('request timeout closes dedicated client without response', () async {
    final c = Client(Request(Reply([])))..stall = true;
    await expectLater(
      HttpOverrides.runWithHttpOverrides(
        () =>
            SeedStatusHttp(timeout: const Duration(milliseconds: 10))
                .post('/v1/manage/seed-sync/status-begin', {'keyId': 'key'}),
        Override(c),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(c.closed, true);
  });
}
