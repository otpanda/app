import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../session_contract.dart';

/// Foreground-only realtime transport for the native client. It speaks the
/// same contract as the web client (tool/realtime-client.js): a bearer POST to
/// /auth/realtime/ticket, then a WebSocket to /auth/realtime offering the
/// subprotocols [otpanda.v1, <ticket>]. The server only ever sends the
/// content-free frame {"v":1,"t":"changed"} and closes on any client frame.
///
/// Listener reasons, identical to the web bridge:
///   'connect', 'changed'            data hints: the caller may re-read
///   'connection-lost',
///   'connection-restored'           state only: the caller must NOT re-read
///
/// There is no polling here and none is added to compensate. The caller owns
/// the app lifecycle: it subscribes while the app is in the foreground and
/// signed in, and unsubscribes (which closes the socket) when it is not.
const realtimeSubprotocol = 'otpanda.v1';
const _closeRevoked = 4401, _closeExpired = 4408, _closeReplaced = 4429;
final _ticketPattern = RegExp(r'^rt1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{43}$');

abstract interface class RealtimeSocket {
  /// Subprotocol the server selected, null if none.
  String? get protocol;

  /// Text frames only. The stream ends when the socket closes.
  Stream<String> get messages;

  /// Close code once the stream has ended, null if unknown.
  int? get closeCode;
  void close([int code = 1000]);
}

typedef RealtimeConnector = Future<RealtimeSocket> Function(
  List<String> protocols,
);

/// Thrown by a [TicketMint] when no request was made because the local session
/// cannot supply a token. [ended] means it is over (signed out, or the server
/// rejected a renewed token twice): realtime stops until the session or the
/// foreground state changes. Otherwise the session is still restoring or
/// paused: a local-only wait that never counts as an unreachable server.
class TicketPause implements Exception {
  const TicketPause({required this.ended});
  final bool ended;
}

typedef TicketMint = Future<SessionResponse> Function();
typedef RealtimeScheduler = Timer Function(Duration d, void Function() f);

class RealtimeConfig {
  const RealtimeConfig({
    this.backoffBaseMs = 1000,
    this.backoffMaxMs = 60000,
    this.stableOpenMs = 30000,
    this.lostAfterMs = 120000,
    this.slowRetryMs = 120000,
    this.replaceBackoffMs = 60000,
    this.replaceCap = 3,
    this.replaceWindowMs = 600000,
    this.degradedMs = 60000,
    this.hiddenPauseMs = 60000,
    this.retryAfterCapMs = 300000,
    this.openTimeoutMs = 15000,
    this.ticketTimeoutMs = 15000,
    this.waitingBaseMs = 1000,
    this.waitingMaxMs = 15000,
    this.fastReconnectMs = 1000,
    this.tooManyMs = 30000,
  });
  final int backoffBaseMs,
      backoffMaxMs,
      stableOpenMs,
      lostAfterMs,
      slowRetryMs,
      replaceBackoffMs,
      replaceCap,
      replaceWindowMs,
      degradedMs,
      hiddenPauseMs,
      retryAfterCapMs,
      openTimeoutMs,
      ticketTimeoutMs,
      waitingBaseMs,
      waitingMaxMs,
      fastReconnectMs,
      tooManyMs;
}

class NativeRealtimeClient {
  NativeRealtimeClient({
    required this.mint,
    required this.connect,
    this.onRevoked,
    this.config = const RealtimeConfig(),
    int Function()? now,
    Random? random,
    RealtimeScheduler? scheduler,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _rand = random ?? Random(),
       _schedule = scheduler ?? ((d, f) => Timer(d, f));

  final TicketMint mint;
  final RealtimeConnector connect;

  /// Called after the server closes a socket because the session was revoked.
  /// The caller runs its normal session check (renew or sign out).
  final Future<void> Function()? onRevoked;
  final RealtimeConfig config;
  final int Function() _now;
  final Random _rand;
  final RealtimeScheduler _schedule;

  final _listeners = <void Function(String)>[];
  bool _running = false, _foreground = true, _paused = false, _ended = false;
  Timer? _hiddenTimer;
  String _state = 'idle';
  int _run = 0;
  Timer? _timer, _lostTimer, _openTimer, _stableTimer;
  RealtimeSocket? _socket;
  StreamSubscription<String>? _sub;
  int _failures = 0, _waits = 0, _openedAt = 0;
  // Failure clock in visible time only. [_clockActive] means counted failures
  // are unresolved; [_accum] is the foreground time already spent; [_segStart]
  // is the start of the current foreground segment (null while backgrounded).
  bool _clockActive = false;
  int _accum = 0;
  int? _segStart;
  String _clockReason = 'unavailable';

  void _resetClock() {
    _clockActive = false;
    _accum = 0;
    _segStart = null;
  }

  bool _lost = false;
  String _lostReason = 'unavailable';
  final _replaced = <int>[];

  bool get running => _running;
  bool get lost => _lost;
  String get lostReason => _lostReason;
  bool get hasSocket => _socket != null;

  /// idle, connecting, open, backoff, waiting, paused, ended.
  String get state => _state;

  /// First subscriber starts the single socket, the last one stops it. A new
  /// subscriber is told at once if the connection is currently lost.
  void Function() subscribe(void Function(String reason) listener) {
    _listeners.add(listener);
    if (_lost) _tell(listener, 'connection-lost');
    if (!_running) _start();
    var done = false;
    return () {
      if (done) return;
      done = true;
      _listeners.remove(listener);
      if (_listeners.isEmpty) _stop();
    };
  }

  void _tell(void Function(String) l, String reason) {
    try {
      l(reason);
    } catch (_) {
      // One listener failing never affects the others or the socket.
    }
  }

  void _emit(String reason) {
    for (final l in List.of(_listeners)) {
      _tell(l, reason);
    }
  }

  void _start() {
    _running = true;
    _run++;
    _failures = 0;
    _waits = 0;
    _resetClock();
    _ended = false;
    _replaced.clear();
    if (!_foreground) {
      _paused = true;
      _state = 'paused';
      return;
    }
    _paused = false;
    _attempt(_run);
  }

  void _stop() {
    _running = false;
    _run++;
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
    _clearTimers();
    _closeSocket(1000);
    _lost = false;
    _paused = false;
    _ended = false;
    _resetClock();
    _state = 'idle';
  }

  /// Foreground accounting (the native equivalent of page visibility). In the
  /// background the socket is kept for [RealtimeConfig.hiddenPauseMs], then
  /// closed with all timers; nothing is retried or counted while paused. Back
  /// in the foreground it reconnects at once with a fresh backoff, and the
  /// open emits 'connect' so the caller catches up.
  void setForeground(bool foreground) {
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (!_running) return;
    if (!foreground) {
      // Freeze the failure clock now, not when the socket pause fires.
      if (_clockActive && _segStart != null) {
        _accum += _now() - _segStart!;
        _segStart = null;
      }
      _lostTimer?.cancel();
      _lostTimer = null;
      _hiddenTimer ??= _schedule(
        Duration(milliseconds: config.hiddenPauseMs),
        () {
          _hiddenTimer = null;
          if (!_foreground && _running) _pause();
        },
      );
      return;
    }
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
    if (_clockActive && _socket == null) {
      _segStart = _now();
      _armLost();
    }
    if (_paused || _ended || (_socket == null && !_connecting)) {
      _reconnectNow();
    }
  }

  void _pause() {
    _run++;
    _clearTimers();
    _closeSocket(1000);
    _connecting = false;
    _resetClock();
    _paused = true;
    _state = 'paused';
  }

  void _reconnectNow() {
    _run++;
    _timer?.cancel();
    _timer = null;
    _openTimer?.cancel();
    _openTimer = null;
    _closeSocket(1000);
    _paused = false;
    _ended = false;
    _failures = 0;
    _waits = 0;
    _replaced.clear();
    _attempt(_run);
  }

  /// The session is over (signed out): drop the socket and every timer but
  /// keep the listeners, and stop trying until [sessionRestored],
  /// a foreground change or a new subscriber.
  void sessionEnded() {
    if (!_running) return;
    _end();
  }

  /// A usable session is back after the end: reconnect now.
  void sessionRestored() {
    if (_running && _ended && _foreground) _reconnectNow();
  }

  void _end() {
    _run++;
    _clearTimers();
    _closeSocket(1000);
    _connecting = false;
    _resetClock();
    _ended = true;
    _state = 'ended';
    // An ended session is not an unreachable server: clear the notice.
    if (_lost) {
      _lost = false;
      _emit('connection-restored');
    }
  }

  bool _connecting = false;

  bool _stale(int id) => !_running || id != _run;

  void _clearTimers() {
    _timer?.cancel();
    _timer = null;
    _lostTimer?.cancel();
    _lostTimer = null;
    _openTimer?.cancel();
    _openTimer = null;
    _stableTimer?.cancel();
    _stableTimer = null;
  }

  void _closeSocket(int code) {
    final s = _socket;
    _socket = null;
    _openTimer?.cancel();
    _openTimer = null;
    _stableTimer?.cancel();
    _stableTimer = null;
    final sub = _sub;
    _sub = null;
    sub?.cancel();
    if (s != null) {
      try {
        s.close(code);
      } catch (_) {}
    }
  }

  void _after(int ms, void Function() f) {
    _timer?.cancel();
    final id = _run;
    _timer = _schedule(Duration(milliseconds: ms), () {
      _timer = null;
      if (!_stale(id)) f();
    });
  }

  double _jitter(int n) {
    final step = min(
      config.backoffMaxMs,
      config.backoffBaseMs * (1 << min(n, 16)),
    );
    // Equal jitter: never below half the step, so no tight loop.
    return step / 2 + _rand.nextDouble() * step / 2;
  }

  /// A counted failure: starts the failure clock and reconnects with backoff.
  void _backoff([int extraMs = 0]) {
    _failures++;
    _markFailure('unavailable');
    final base = _jitter(_failures - 1).round();
    final floor = min(extraMs, config.retryAfterCapMs);
    final wait = floor > 0
        ? max(floor + (_rand.nextDouble() * 1000).round(), base)
        : base;
    _state = 'backoff';
    _state = 'backoff';
    _after(wait, () => _attempt(_run));
  }

  /// Not signed in yet (no token): not a server failure, never starts the
  /// clock. Retries locally with a short capped backoff.
  void _waiting() {
    _state = 'waiting';
    _resetClock();
    _lostTimer?.cancel();
    _lostTimer = null;
    _waits++;
    final step = min(
      config.waitingMaxMs,
      config.waitingBaseMs * (1 << min(_waits - 1, 16)),
    );
    _after(step, () => _attempt(_run));
  }

  /// Failure that is not an auth state: ticket 404 (feature inactive) or a
  /// rejection (400/403/405, close 1008). It is reported at once and retried
  /// slowly (60 to 120 s, equal jitter) so a rollout or a challenge page can
  /// recover without polling and without a tight loop.
  void _slowLost(String reason, {int floorMs = 0}) {
    _closeSocket(1000);
    _raiseLost(reason);
    _state = 'backoff';
    floorMs = min(floorMs, config.retryAfterCapMs);
    final step = config.slowRetryMs;
    final wait = max(
      floorMs,
      (step / 2 + _rand.nextDouble() * step / 2).round(),
    );
    _after(wait, () => _attempt(_run));
  }

  void _raiseLost(String reason) {
    _lostTimer?.cancel();
    _lostTimer = null;
    if (!_foreground) {
      // A reply that lands while backgrounded never raises the notice.
      return;
    }
    _lostReason = reason;
    if (_lost) return;
    _lost = true;
    _emit('connection-lost');
  }

  void _markFailure(String reason) {
    if (!_running) return;
    _clockReason = reason;
    if (!_clockActive) {
      _clockActive = true;
      _accum = 0;
      _segStart = null;
    }
    if (_foreground) _segStart ??= _now();
    _armLost();
  }

  int _elapsed() => _accum + (_segStart == null ? 0 : _now() - _segStart!);

  /// Arms (or raises) the lost timer from visible time. Nothing runs while
  /// backgrounded: the clock is frozen, not advanced.
  void _armLost() {
    _lostTimer?.cancel();
    _lostTimer = null;
    // A healthy open socket freezes the clock: only a missing socket counts.
    if (!_clockActive || _lost || !_foreground || _socket != null) return;
    final remaining = config.lostAfterMs - _elapsed();
    if (remaining <= 0) {
      _raiseLost(_clockReason);
      return;
    }
    _lostTimer = _schedule(Duration(milliseconds: remaining), () {
      _lostTimer = null;
      if (_running && _clockActive && _foreground) _raiseLost(_clockReason);
    });
  }

  int _retryAfterMs(SessionResponse r) {
    final v = r.retryAfterSeconds;
    if (v == null || v <= 0) return 0;
    return min(config.retryAfterCapMs, v * 1000);
  }

  void _closeQuiet(RealtimeSocket s) {
    try {
      s.close(1000);
    } catch (_) {}
  }

  /// Opens the socket with a deadline that cannot leak: if the connector
  /// outlives the deadline (or this attempt goes stale first) its late socket
  /// is closed the moment it arrives. Returns null on timeout.
  Future<RealtimeSocket?> _open(List<String> protocols, int id) {
    final c = Completer<RealtimeSocket?>();
    final timer = _schedule(Duration(milliseconds: config.openTimeoutMs), () {
      if (!c.isCompleted) c.complete(null);
    });
    Future<RealtimeSocket> f;
    try {
      f = connect(protocols);
    } catch (e) {
      timer.cancel();
      return Future.error(e);
    }
    f.then(
      (s) {
        if (c.isCompleted || _stale(id)) {
          timer.cancel();
          _closeQuiet(s);
          if (!c.isCompleted) c.complete(null);
        } else {
          timer.cancel();
          c.complete(s);
        }
      },
      onError: (Object e) {
        timer.cancel();
        if (!c.isCompleted) c.completeError(e);
      },
    );
    return c.future;
  }

  Future<void> _attempt(int id) async {
    if (_stale(id)) return;
    if (!_foreground) {
      // Hidden: no attempt before the pause either. Foreground retries now.
      _state = 'backoff';
      return;
    }
    _connecting = true;
    _state = 'connecting';
    try {
      await _attemptInner(id);
    } finally {
      if (id == _run) _connecting = false;
    }
  }

  Future<void> _attemptInner(int id) async {
    SessionResponse res;
    try {
      res = await mint().timeout(
        Duration(milliseconds: config.ticketTimeoutMs),
      );
    } on TicketPause catch (p) {
      if (_stale(id)) return;
      if (p.ended) return _end();
      return _waiting();
    } catch (_) {
      if (_stale(id)) return;
      return _backoff();
    }
    if (_stale(id)) return;
    final s = res.status;
    if (s == 401) return _waiting();
    if (s == 404) return _slowLost('unavailable', floorMs: _retryAfterMs(res));
    if (s == 400 || s == 403 || s == 405) return _slowLost('rejected');
    if (s == 429) {
      return _backoff(max(config.tooManyMs, _retryAfterMs(res)));
    }
    if (s == 503) return _backoff(_retryAfterMs(res));
    if (s != 200) return _backoff();
    String? ticket;
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['ticket'] is String) {
        ticket = body['ticket'] as String;
      }
    } catch (_) {}
    if (ticket == null || !_ticketPattern.hasMatch(ticket)) return _backoff();
    _waits = 0;
    RealtimeSocket? sock;
    try {
      sock = await _open([realtimeSubprotocol, ticket], id);
    } catch (_) {
      if (_stale(id)) return;
      return _backoff();
    }
    if (_stale(id)) {
      if (sock != null) _closeQuiet(sock);
      return;
    }
    if (sock == null) return _backoff();
    if (sock.protocol != realtimeSubprotocol) {
      try {
        sock.close(1008);
      } catch (_) {}
      return _backoff();
    }
    _socket = sock;
    _openedAt = _now();
    _state = 'open';
    // A plain open clears the notice at once. The failure clock only resets
    // after a stable period, so a flapping server shows it again quickly.
    _lostTimer?.cancel();
    _lostTimer = null;
    if (_clockActive && _segStart != null) {
      _accum += _now() - _segStart!;
      _segStart = null;
    }
    _stableTimer?.cancel();
    final opened0 = sock;
    _stableTimer = _schedule(Duration(milliseconds: config.stableOpenMs), () {
      _stableTimer = null;
      if (_running && _socket == opened0) {
        _failures = 0;
        _resetClock();
      }
    });
    if (_lost) {
      _lost = false;
      _emit('connection-restored');
    }
    _emit('connect');
    final opened = sock;
    _sub = opened.messages.listen(
      (data) {
        if (_stale(id) || _socket != opened || data.length > 256) return;
        try {
          final m = jsonDecode(data);
          if (m is Map && m['v'] == 1 && m['t'] == 'changed') {
            _emit('changed');
          }
        } catch (_) {}
      },
      onError: (_) {},
      onDone: () => _closed(id, opened),
      cancelOnError: false,
    );
  }

  void _closed(int id, RealtimeSocket sock) {
    if (_stale(id) || _socket != sock) return;
    final code = sock.closeCode;
    _socket = null;
    _sub = null;
    _stableTimer?.cancel();
    _stableTimer = null;
    _state = 'backoff';
    final stable = _now() - _openedAt >= config.stableOpenMs;
    if (stable) {
      _failures = 0;
      _resetClock();
    }
    if (code == _closeRevoked) {
      // No immediate reconnect. The session check decides (renew or sign out);
      // if the session is still valid the next ticket attempt backs off.
      final rid = _run;
      Future<void>.sync(() => onRevoked?.call()).catchError((_) {}).then((_) {
        if (!_stale(rid) && _timer == null) _backoff();
      });
      return;
    }
    if (code == _closeExpired || code == 1006 || code == 1001 || code == null) {
      if (stable) {
        _after(
          (_rand.nextDouble() * config.fastReconnectMs).round(),
          () => _attempt(_run),
        );
        return;
      }
      return _backoff();
    }
    if (code == _closeReplaced) {
      final t = _now();
      _replaced.removeWhere((x) => t - x >= config.replaceWindowMs);
      _replaced.add(t);
      if (_replaced.length >= config.replaceCap) {
        _replaced.clear();
        _markFailure('rejected');
        _state = 'degraded';
        _after(config.degradedMs, () => _attempt(_run));
        return;
      }
      _after(
        config.replaceBackoffMs + (_rand.nextDouble() * 1000).round(),
        () => _attempt(_run),
      );
      return;
    }
    if (code == 1008) return _slowLost('rejected');
    _backoff();
  }
}
