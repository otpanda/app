import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_realtime.dart';
import 'package:otpanda_client/session_contract.dart';

final _ticket = 'rt1.${'A' * 16}.${'B' * 43}';

class _Timer implements Timer {
  _Timer(this.at, this.fn);
  final int at;
  final void Function() fn;
  bool cancelled = false, fired = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => 0;
}

class _Clock {
  int now = 1000000;
  final timers = <_Timer>[];
  Timer schedule(Duration d, void Function() f) {
    final t = _Timer(now + d.inMilliseconds, f);
    timers.add(t);
    return t;
  }

  Future<void> flush() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> advance(int ms) async {
    final end = now + ms;
    while (true) {
      final due = timers.where((t) => t.isActive && t.at <= end).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      now = max(now, t.at);
      t.fired = true;
      t.fn();
      await flush();
    }
    now = end;
    await flush();
  }
}

class _Sock implements RealtimeSocket {
  _Sock({this.protocol = realtimeSubprotocol});
  final c = StreamController<String>();
  @override
  final String? protocol;
  @override
  Stream<String> get messages => c.stream;
  @override
  int? closeCode;
  int? closedWith;
  @override
  void close([int code = 1000]) => closedWith = code;
  void frame(String s) => c.add(s);
  Future<void> end(int? code) async {
    closeCode = code;
    await c.close();
  }
}

void main() {
  late _Clock clk;
  late List<int> ticketStatuses;
  late List<List<String>> connects;
  late List<_Sock> socks;
  late NativeRealtimeClient client;
  late List<String> got;
  var mints = 0;
  final retryAfters = <int?>[];
  Future<RealtimeSocket> Function(List<String>)? connectOverride;

  NativeRealtimeClient make() => NativeRealtimeClient(
    mint: () async {
      mints++;
      final s = ticketStatuses.isEmpty ? 200 : ticketStatuses.removeAt(0);
      return SessionResponse(
        s,
        s == 200 ? jsonEncode({'ticket': _ticket}) : '{}',
        retryAfterSeconds: retryAfters.isEmpty ? null : retryAfters.removeAt(0),
      );
    },
    connect: (p) async {
      if (connectOverride != null) {
        connects.add(p);
        return connectOverride!(p);
      }
      connects.add(p);
      final s = _Sock();
      socks.add(s);
      return s;
    },
    now: () => clk.now,
    random: Random(1),
    scheduler: clk.schedule,
  );

  setUp(() {
    clk = _Clock();
    ticketStatuses = [];
    connects = [];
    socks = [];
    got = [];
    mints = 0;
    retryAfters.clear();
    connectOverride = null;
    client = make();
  });

  test(
    'one ticket, one socket, subprotocols only; hints; last unsubscribe closes',
    () async {
      final stop = client.subscribe(got.add);
      final stop2 = client.subscribe((_) {});
      await clk.flush();
      expect(mints, 1);
      expect(connects, [
        [realtimeSubprotocol, _ticket],
      ]);
      expect(got, ['connect']);
      socks[0].frame('{"v":1,"t":"changed"}');
      socks[0].frame('not json');
      socks[0].frame('{"v":2,"t":"changed"}');
      socks[0].frame('{"v":1,"t":"other"}');
      socks[0].frame('x' * 300);
      await clk.flush();
      expect(got, ['connect', 'changed']);
      stop();
      expect(socks[0].closedWith, isNull, reason: 'one subscriber remains');
      stop2();
      expect(socks[0].closedWith, 1000);
      expect(client.running, isFalse);
    },
  );

  test('wrong subprotocol is refused and retried with backoff', () async {
    final bad = NativeRealtimeClient(
      mint: () async => SessionResponse(200, jsonEncode({'ticket': _ticket})),
      connect: (p) async {
        connects.add(p);
        final s = _Sock(protocol: null);
        socks.add(s);
        return s;
      },
      now: () => clk.now,
      random: Random(1),
      scheduler: clk.schedule,
    );
    bad.subscribe(got.add);
    await clk.flush();
    expect(socks[0].closedWith, 1008);
    expect(got, isEmpty);
    expect(connects, hasLength(1));
    await clk.advance(70000);
    expect(connects.length, greaterThan(1));
  });

  test('401 means not signed in: waits locally, never lost', () async {
    ticketStatuses = List.filled(30, 401, growable: true);
    client.subscribe(got.add);
    await clk.advance(600000);
    expect(got, isEmpty);
    expect(client.lost, isFalse);
  });

  test('failures raise lost at 120 s, a new subscriber is told, recovery orders restored then connect', () async {
    ticketStatuses = List.filled(100, 503, growable: true);
    client.subscribe(got.add);
    await clk.flush();
    await clk.advance(119000);
    expect(got, isEmpty);
    await clk.advance(2000);
    expect(got, ['connection-lost']);
    final late = <String>[];
    client.subscribe(late.add);
    expect(late, ['connection-lost'], reason: 'replayed synchronously');
    ticketStatuses.clear();
    await clk.advance(70000);
    expect(got, ['connection-lost', 'connection-restored', 'connect']);
    expect(late, ['connection-lost', 'connection-restored', 'connect']);
    expect(client.lost, isFalse);
  });

  test('ticket 404 and 400/403/405 are lost at once and retried slowly, 404 then 200 recovers', () async {
    for (final s in [404, 400, 403, 405]) {
      clk = _Clock();
      mints = 0;
      got = [];
      ticketStatuses = [s];
      client = make();
      client.subscribe(got.add);
      await clk.flush();
      expect(got, ['connection-lost'], reason: 'status $s');
      expect(client.lostReason, s == 404 ? 'unavailable' : 'rejected');
      await clk.advance(59000);
      expect(mints, 1, reason: 'no retry before 60 s');
      await clk.advance(62000);
      expect(mints, 2, reason: 'retry within 60 to 120 s');
      expect(got, ['connection-lost', 'connection-restored', 'connect']);
    }
  });

  test('close 1008 is lost with a slow retry, not a stop', () async {
    client.subscribe(got.add);
    await clk.flush();
    await socks[0].end(1008);
    await clk.flush();
    expect(got, ['connect', 'connection-lost']);
    await clk.advance(121000);
    expect(socks, hasLength(2));
  });

  test(
    'stable expiry reconnects fast; an early close backs off and counts',
    () async {
      client.subscribe(got.add);
      await clk.flush();
      clk.now += 31000;
      await socks[0].end(4408);
      await clk.advance(1100);
      expect(socks, hasLength(2), reason: 'fast reconnect after a stable open');
      await socks[1].end(1006);
      await clk.flush();
      expect(socks, hasLength(2), reason: 'early close waits for backoff');
      await clk.advance(2100);
      expect(socks.length, 3);
    },
  );

  test(
    'flapping server: restored on open, lost again at the next failure',
    () async {
      ticketStatuses = List.filled(100, 503, growable: true);
      client.subscribe(got.add);
      await clk.flush();
      await clk.advance(125000);
      ticketStatuses.clear();
      for (var i = 0; i < 70 && socks.isEmpty; i++) {
        await clk.advance(1000);
      }
      expect(got.last, 'connect');
      await socks.last.end(1006);
      await clk.flush();
      expect(got.where((r) => r == 'connection-lost').length, 2);
    },
  );

  test(
    'revoked close asks the session check and does not reconnect at once',
    () async {
      var asked = 0;
      final c = NativeRealtimeClient(
        mint: () async => SessionResponse(200, jsonEncode({'ticket': _ticket})),
        connect: (p) async {
          final s = _Sock();
          socks.add(s);
          return s;
        },
        onRevoked: () async => asked++,
        now: () => clk.now,
        random: Random(1),
        scheduler: clk.schedule,
      );
      c.subscribe(got.add);
      await clk.flush();
      await socks[0].end(4401);
      await clk.flush();
      expect(asked, 1);
      expect(socks, hasLength(1));
      await clk.advance(3000);
      expect(socks.length, 2);
    },
  );

  test(
    'a throwing listener does not break others; stop clears the notice state',
    () async {
      ticketStatuses = [404];
      final ok = <String>[];
      client.subscribe((_) => throw StateError('x'));
      final stop = client.subscribe(ok.add);
      await clk.flush();
      expect(ok, ['connection-lost']);
      stop();
      expect(client.lost, isTrue, reason: 'one listener left');
    },
  );

  test('malformed ticket is a counted failure, never a connection', () async {
    final c = NativeRealtimeClient(
      mint: () async => const SessionResponse(200, '{"ticket":"nope"}'),
      connect: (p) async {
        socks.add(_Sock());
        return socks.last;
      },
      now: () => clk.now,
      random: Random(1),
      scheduler: clk.schedule,
    );
    c.subscribe(got.add);
    await clk.advance(10000);
    expect(socks, isEmpty);
  });

  test(
    'a connect that outlives its deadline is closed when it finally arrives',
    () async {
      final late = Completer<RealtimeSocket>();
      connectOverride = (_) => late.future;
      client.subscribe(got.add);
      await clk.flush();
      await clk.advance(15001);
      expect(client.state, 'backoff');
      final s = _Sock();
      late.complete(s);
      await clk.flush();
      expect(s.closedWith, 1000);
      expect(client.hasSocket, isFalse);
      expect(got, isNot(contains('connect')));
    },
  );

  test(
    'unsubscribing during a pending connect closes the late socket',
    () async {
      final late = Completer<RealtimeSocket>();
      connectOverride = (_) => late.future;
      final stop = client.subscribe(got.add);
      await clk.flush();
      stop();
      final s = _Sock();
      late.complete(s);
      await clk.flush();
      expect(s.closedWith, 1000);
      expect(got, isEmpty);
      expect(client.state, 'idle');
    },
  );

  test('Retry-After on 429 and 503 is a bounded floor', () async {
    ticketStatuses = [503, 200];
    retryAfters.add(90);
    client.subscribe(got.add);
    await clk.flush();
    expect(mints, 1);
    await clk.advance(89000);
    expect(mints, 1);
    await clk.advance(2500);
    expect(mints, 2);
    expect(got, contains('connect'));
    // A huge value is capped at 300 s.
    final c2 = make();
    ticketStatuses = [429, 200];
    retryAfters.add(999999);
    c2.subscribe((_) {});
    await clk.flush();
    final before = mints;
    await clk.advance(299000);
    expect(mints, before);
    await clk.advance(2500);
    expect(mints, before + 1);
  });

  test('429 without Retry-After still waits at least 30 s', () async {
    ticketStatuses = [429, 200];
    client.subscribe(got.add);
    await clk.flush();
    await clk.advance(29000);
    expect(mints, 1);
    await clk.advance(2500);
    expect(mints, 2);
  });

  test('auth ended: no lost, no more requests, restored reconnects', () async {
    var ended = true, n = 0;
    final c = NativeRealtimeClient(
      mint: () async {
        n++;
        if (ended) throw const TicketPause(ended: true);
        return SessionResponse(200, jsonEncode({'ticket': _ticket}));
      },
      connect: (p) async {
        final s = _Sock();
        socks.add(s);
        return s;
      },
      now: () => clk.now,
      random: Random(1),
      scheduler: clk.schedule,
    );
    c.subscribe(got.add);
    await clk.flush();
    await clk.advance(600000);
    expect(n, 1);
    expect(c.state, 'ended');
    expect(c.lost, isFalse);
    expect(got, isEmpty);
    ended = false;
    c.sessionRestored();
    await clk.flush();
    expect(c.state, 'open');
    expect(got, ['connect']);
  });

  test(
    'session paused (not ended) waits locally and never raises lost',
    () async {
      var n = 0;
      final c = NativeRealtimeClient(
        mint: () async {
          n++;
          throw const TicketPause(ended: false);
        },
        connect: (p) async => _Sock(),
        now: () => clk.now,
        random: Random(1),
        scheduler: clk.schedule,
      );
      c.subscribe(got.add);
      await clk.flush();
      await clk.advance(400000);
      expect(n, greaterThan(3));
      expect(c.lost, isFalse);
      expect(got, isEmpty);
    },
  );

  test(
    'sessionEnded tears the socket down, keeps listeners, clears lost',
    () async {
      client.subscribe(got.add);
      await clk.flush();
      final s = socks.single;
      client.sessionEnded();
      expect(s.closedWith, 1000);
      expect(client.hasSocket, isFalse);
      expect(client.state, 'ended');
      final m = mints;
      await clk.advance(300000);
      expect(mints, m);
      client.sessionRestored();
      await clk.flush();
      expect(client.state, 'open');
      expect(got.where((e) => e == 'connect').length, 2);
    },
  );

  test(
    'three replaced closes wait the 60 s degraded cap and count as a failure',
    () async {
      client.subscribe(got.add);
      await clk.flush();
      for (var i = 0; i < 3; i++) {
        await socks.last.end(4429);
        await clk.flush();
        if (i < 2) await clk.advance(62000);
      }
      final m = mints;
      await clk.advance(59000);
      expect(mints, m);
      await clk.advance(2000);
      expect(mints, m + 1);
    },
  );

  test('background keeps the socket for 60 s, then pauses; resume reconnects at once', () async {
    client.subscribe(got.add);
    await clk.flush();
    client.setForeground(false);
    await clk.advance(59000);
    expect(client.hasSocket, isTrue);
    client.setForeground(true);
    await clk.advance(120000);
    expect(mints, 1, reason: 'short background changes nothing');
    client.setForeground(false);
    await clk.advance(61000);
    expect(client.state, 'paused');
    expect(socks.last.closedWith, 1000);
    final m = mints;
    await clk.advance(600000);
    expect(mints, m, reason: 'nothing is retried while paused');
    client.setForeground(true);
    await clk.flush();
    expect(mints, m + 1);
    expect(client.state, 'open');
    expect(got.where((e) => e == 'connect').length, 2, reason: 'catch-up');
  });

  test(
    'pause stops the failure clock and a later resume starts fresh',
    () async {
      ticketStatuses = [500, 500, 500, 500, 500, 500];
      client.subscribe(got.add);
      await clk.flush();
      await clk.advance(30000);
      client.setForeground(false);
      await clk.advance(61000);
      await clk.advance(300000);
      expect(client.lost, isFalse);
      ticketStatuses = [];
      client.setForeground(true);
      await clk.flush();
      expect(client.state, 'open');
      expect(client.lost, isFalse);
    },
  );

  test(
    'subscribing while in the background waits for the foreground',
    () async {
      client.setForeground(false);
      client.subscribe(got.add);
      await clk.flush();
      expect(mints, 0);
      expect(client.state, 'paused');
      client.setForeground(true);
      await clk.flush();
      expect(mints, 1);
      expect(got, ['connect']);
    },
  );

  test('foreground in backoff retries now with a fresh backoff', () async {
    ticketStatuses = [500, 500, 500, 500, 500, 500];
    client.subscribe(got.add);
    await clk.flush();
    await clk.advance(2500);
    expect(client.state, 'backoff');
    final before = mints;
    client.setForeground(false);
    client.setForeground(true);
    await clk.flush();
    expect(mints, before + 1);
  });

  test('background freezes the failure clock at once: short background never raises lost', () async {
    ticketStatuses = List.filled(300, 500);
    client.subscribe(got.add);
    await clk.flush();
    await clk.advance(100000);
    expect(client.lost, isFalse);
    client.setForeground(false);
    await clk.advance(55000);
    expect(client.lost, isFalse, reason: 'frozen at 100 s, not 155 s');
    client.setForeground(true);
    await clk.advance(18000);
    expect(client.lost, isFalse);
    await clk.advance(3000);
    expect(client.lost, isTrue, reason: '100 s + about 20 s visible');
    expect(got, ['connection-lost']);
  });

  test(
    'background before a 404 lands defers the notice and foreground clears it',
    () async {
      final gate = Completer<void>();
      final c = NativeRealtimeClient(
        mint: () async {
          await gate.future;
          return const SessionResponse(404, '{}');
        },
        connect: (p) async => _Sock(),
        now: () => clk.now,
        random: Random(1),
        scheduler: clk.schedule,
      );
      c.subscribe(got.add);
      await clk.flush();
      c.setForeground(false);
      gate.complete();
      await clk.flush();
      expect(c.lost, isFalse);
      expect(got, isEmpty);
    },
  );

  test('a healthy open freezes the failure clock: fail, open 3 min, background, resume never raises lost', () async {
    ticketStatuses = [500, 500, 500, 500, 500, 500, 200];
    client.subscribe(got.add);
    await clk.flush();
    await clk.advance(110000);
    expect(client.state, 'open');
    expect(client.lost, isFalse);
    await clk.advance(180000);
    client.setForeground(false);
    await clk.advance(61000);
    client.setForeground(true);
    await clk.advance(130000);
    expect(client.lost, isFalse);
    expect(got.where((e) => e == 'connection-lost'), isEmpty);
  });

  test('open for under 30 s then background and resume on the same socket never raises lost', () async {
    ticketStatuses = [500, 500, 500, 500, 500, 500, 200];
    client.subscribe(got.add);
    await clk.flush();
    await clk.advance(100000);
    expect(client.state, 'open');
    await clk.advance(5000);
    client.setForeground(false);
    await clk.advance(20000);
    client.setForeground(true);
    await clk.advance(300000);
    expect(client.lost, isFalse);
    expect(socks.length, 1, reason: 'the same socket, no reconnect');
  });

  test('a flapping server still reaches lost: the clock only resets after 30 s stable', () async {
    ticketStatuses = List.filled(5, 500);
    client.subscribe(got.add);
    await clk.flush();
    await clk.advance(70000);
    for (var i = 0; i < 12 && !client.lost; i++) {
      if (socks.isNotEmpty && client.hasSocket) {
        await socks.last.end(1006);
        await clk.flush();
      }
      await clk.advance(10000);
    }
    expect(client.lost, isTrue);
  });

  test('ending the session clears lost with a restored notice', () async {
    ticketStatuses = [404, 404];
    client.subscribe(got.add);
    await clk.flush();
    expect(got, ['connection-lost']);
    client.sessionEnded();
    expect(got, ['connection-lost', 'connection-restored']);
    expect(client.lost, isFalse);
    expect(client.state, 'ended');
  });

  test(
    'no attempts while hidden before the pause; foreground retries now',
    () async {
      ticketStatuses = List.filled(20, 500);
      client.subscribe(got.add);
      await clk.flush();
      client.setForeground(false);
      final m = mints;
      await clk.advance(59000);
      expect(mints, m);
      client.setForeground(true);
      await clk.flush();
      expect(mints, m + 1);
    },
  );

  test('three replaced closes show the degraded state at once', () async {
    client.subscribe(got.add);
    await clk.flush();
    for (var i = 0; i < 3; i++) {
      await socks.last.end(4429);
      await clk.flush();
      if (i < 2) await clk.advance(62000);
    }
    expect(client.state, 'degraded');
  });
}
