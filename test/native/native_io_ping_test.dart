import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_realtime.dart';

void main() {
  test(
    'control-frame ping detects a half-open socket; a live peer stays open',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final serverSockets = <WebSocket>[];
      final subs = <StreamSubscription<dynamic>>[];
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(
          req,
          protocolSelector: (p) => realtimeSubprotocol,
        );
        serverSockets.add(ws);
        subs.add(ws.listen((_) {}));
      });
      final uri = Uri.parse('ws://127.0.0.1:${server.port}/auth/realtime');
      final connect = ioRealtimeConnector(
        uri,
        pingInterval: const Duration(milliseconds: 150),
      );
      final live = await connect([realtimeSubprotocol, 'x']);
      expect(live.protocol, realtimeSubprotocol);
      final done = Completer<void>();
      live.messages.listen((_) {}, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(live.closeCode, isNull, reason: 'pongs keep it open');
      // Half-open: the peer stops reading, so no pong ever comes back.
      for (final s in subs) {
        s.pause();
      }
      await done.future.timeout(const Duration(seconds: 5));
      expect(live.closeCode, isNotNull);
      for (final s in serverSockets) {
        await s.close();
      }
      await server.close(force: true);
    },
  );
}
