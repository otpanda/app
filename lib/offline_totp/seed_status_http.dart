import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'seed_status_coordinator.dart';

/// Dedicated credential-free client. Never reuses the authenticated API client.
/// DIRECT intentionally ignores proxy configuration. A proxy-only network fails
/// closed and returns retry through the coordinator, never a purge.
/// Unregistered until native channel and lifecycle qualification complete.
final class SeedStatusHttp implements SeedStatusTransport {
  SeedStatusHttp({
    this.timeout = const Duration(seconds: 15),
    String origin = 'https://otpanda-api.abrahammurciano.workers.dev',
  }) : _origin = Uri.parse(origin) {
    if (_origin.hasQuery ||
        _origin.hasFragment ||
        _origin.userInfo.isNotEmpty ||
        (_origin.path.isNotEmpty && _origin.path != '/') ||
        (_origin.scheme != 'https' &&
            !(_origin.scheme == 'http' && _origin.host == '127.0.0.1')) ||
        _origin.host.isEmpty) {
      throw ArgumentError(
        'status origin must be HTTPS or qualification loopback',
      );
    }
  }
  final Duration timeout;
  // Engineering bound: retry at most hourly even if a proxy/server supplies a
  // multi-day delay, so revocation is not postponed for days. A 429 can never
  // cause a fast loop: coordinator takes max(local exponential, this delay).
  static const _maxRetryDelay = Duration(hours: 1);
  final Uri _origin;
  static const _paths = {
    '/v1/manage/seed-sync/status-begin',
    '/v1/manage/seed-sync/status-finish',
  };
  @override
  Future<SeedStatusResponse> post(String path, Map<String, Object> body) async {
    if (!_paths.contains(path)) throw ArgumentError('unsupported status route');
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final request = await client.postUrl(_origin.replace(path: path));
        request.followRedirects = false;
        request.maxRedirects = 0;
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        // New client, no credentials/authenticate callback, no cookie store.
        request.write(jsonEncode(body));
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 4096) {
            throw const FormatException('status body too large');
          }
          bytes.addAll(chunk);
        }
        final text = utf8.decode(bytes, allowMalformed: false);
        Duration? delay;
        final retry = response.headers.value(HttpHeaders.retryAfterHeader);
        final seconds = int.tryParse(retry ?? '');
        if (seconds != null && seconds >= 0) {
          delay = Duration(seconds: seconds.clamp(0, 2147483647));
        } else if (retry != null) {
          try {
            final d = HttpDate.parse(retry).difference(DateTime.now());
            if (!d.isNegative) {
              delay = d;
            }
          } catch (_) {}
        }
        return SeedStatusResponse(
          response.statusCode,
          text,
          retryAfter: delay != null && delay > _maxRetryDelay
              ? _maxRetryDelay
              : delay,
        );
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}
