import 'dart:convert';

/// Inactive owner-only review model. This never contains or provides a code.
/// Endpoint shape must be reconciled with the API candidate before registration.
final class UnassignedContext {
  const UnassignedContext._({
    required this.contextId,
    required this.sourceId,
    required this.eventId,
    required this.kind,
    required this.sender,
    required this.sourceLabel,
    required this.receivedAt,
    required this.arrivedAt,
    required this.retainedUntil,
    required this.redactedText,
    required this.contextUnavailable,
    required this.truncated,
  });

  final String contextId, sourceId, eventId, kind, sender, sourceLabel;
  final int receivedAt, arrivedAt, retainedUntil;
  final String? redactedText;
  final bool contextUnavailable, truncated;

  factory UnassignedContext.fromJson(Map<String, dynamic> json) {
    const keys = {
      'contextId',
      'sourceId',
      'eventId',
      'kind',
      'sender',
      'sourceLabel',
      'receivedAt',
      'arrivedAt',
      'retainedUntil',
      'redactedText',
      'contextUnavailable',
      'truncated',
    };
    Never bad() => throw const FormatException('Invalid review context');
    if (json.keys.any((k) => !keys.contains(k))) bad();
    String text(String key, int max) {
      final value = json[key];
      if (value is! String ||
          value.isEmpty ||
          utf8.encode(value).length > max ||
          value.codeUnits.any((c) => c < 32 || c == 127)) {
        bad();
      }
      return value;
    }

    final kind = text('kind', 16);
    if (!{'sms', 'email'}.contains(kind)) bad();
    final received = json['receivedAt'],
        arrived = json['arrivedAt'],
        retained = json['retainedUntil'];
    if (received is! int ||
        arrived is! int ||
        retained is! int ||
        received < 0 ||
        arrived < received ||
        retained <= arrived ||
        retained - arrived > 30 * 86400000) {
      bad();
    }
    final unavailable = json['contextUnavailable'],
        truncated = json['truncated'];
    if (unavailable is! bool || truncated is! bool) bad();
    final body = json['redactedText'];
    if (unavailable ? body != null : body is! String || body.isEmpty) bad();
    if (body is String &&
        (utf8.encode(body).length > (kind == 'sms' ? 4096 : 1024) ||
            body.codeUnits.any(
              (c) => (c < 32 && c != 10 && c != 9) || c == 127,
            ))) {
      bad();
    }
    return UnassignedContext._(
      contextId: text('contextId', 256),
      sourceId: text('sourceId', 256),
      eventId: text('eventId', 256),
      kind: kind,
      sender: text('sender', 256),
      sourceLabel: text('sourceLabel', 480),
      receivedAt: received,
      arrivedAt: arrived,
      retainedUntil: retained,
      redactedText: body as String?,
      contextUnavailable: unavailable,
      truncated: truncated,
    );
  }

  bool retained(int now) => arrivedAt <= now && now < retainedUntil;
  String get contentLabel =>
      kind == 'sms' ? 'Message, code redacted' : 'Subject, code redacted';
  @override
  String toString() => 'UnassignedContext(redacted)';
}
