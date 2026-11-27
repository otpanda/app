import 'dart:convert';

String _encode(String id) =>
    base64Url.encode(utf8.encode(id)).replaceAll('=', '');
String accountDetailRoute(String id) => 'accounts/${_encode(id)}';
String unassignedDetailRoute(String sourceId, String eventId) =>
    'unassigned-details/${_encode(sourceId)}/${_encode(eventId)}';

final class DetailRoute {
  final String? accountId, sourceId, eventId;
  const DetailRoute.account(this.accountId) : sourceId = null, eventId = null;
  const DetailRoute.unassigned(this.sourceId, this.eventId) : accountId = null;
}

DetailRoute? parseDetailRoute(String? route) {
  if (route == null) return null;
  final parts = route.split('/');
  String decode(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{2,1366}$').hasMatch(value)) {
      throw const FormatException();
    }
    final id = utf8.decode(base64Url.decode(base64Url.normalize(value)));
    if (id.isEmpty ||
        id.length > 1024 ||
        id.codeUnits.any((c) => c < 32 || c == 127) ||
        _encode(id) != value) {
      throw const FormatException();
    }
    return id;
  }

  try {
    if (parts.length == 2 && parts[0] == 'accounts') {
      return DetailRoute.account(decode(parts[1]));
    }
    if (parts.length == 3 && parts[0] == 'unassigned-details') {
      return DetailRoute.unassigned(decode(parts[1]), decode(parts[2]));
    }
  } on FormatException {
    return null;
  }
  return null;
}
