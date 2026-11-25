import 'dart:convert';

/// Most websites one viewer can attach to one entry: the server's maximum
/// (32, per the API owner via primary).
const entryDomainsMax = 32;

final _label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
const _reservedTlds = {'local', 'localhost', 'internal', 'lan', 'arpa'};

/// One exact public HTTPS host, or null. Accepts a bare host or an
/// `https://host` / `https://host/` paste. Never accepts a wildcard, a port,
/// credentials, a query, a path, an IP address, a single label, a reserved
/// private suffix or any non-ASCII text. Subdomains and parents are never
/// implied: `example.com` matches only `example.com`.
///
/// Not checked here: whether the name is itself a public suffix (needs the
/// public suffix list). The API's own normalizer is the authority on that.
String? normalizeEntryDomain(String input) {
  var v = input.trim().toLowerCase();
  if (v.startsWith('https://')) {
    v = v.substring(8);
    if (v.endsWith('/')) v = v.substring(0, v.length - 1);
  }
  if (v.isEmpty || v.length > 253) return null;
  final labels = v.split('.');
  if (labels.length < 2) return null;
  if (!labels.every(_label.hasMatch)) return null;
  final tld = labels.last;
  if (RegExp(r'^[0-9]+$').hasMatch(tld) || _reservedTlds.contains(tld)) {
    return null;
  }
  return v;
}

/// Domains from GET /v1/manage/entry/domains for the viewer:
/// {associations:[{entryId, domains:[...]}]}. Throws FormatException on any
/// other shape, an invalid host or a duplicate entry, so a partial or odd
/// answer is never mistaken for "no websites".
Map<String, List<String>> parseEntryDomains(String body) {
  if (body.length > 262144) throw const FormatException('Too large');
  final j = jsonDecode(body);
  if (j is! Map<String, dynamic>) throw const FormatException('Object');
  final list = j['associations'];
  if (list is! List || list.length > 1000) throw const FormatException('List');
  final out = <String, List<String>>{};
  for (final a in list) {
    if (a is! Map<String, dynamic>) throw const FormatException('Item');
    final id = a['entryId'], d = a['domains'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 256 ||
        d is! List ||
        d.length > entryDomainsMax ||
        out.containsKey(id)) {
      throw const FormatException('Item');
    }
    final hosts = <String>[];
    for (final x in d) {
      final h = x is String ? normalizeEntryDomain(x) : null;
      if (h == null || h != x || hosts.contains(h)) {
        throw const FormatException('Domain');
      }
      hosts.add(h);
    }
    out[id] = hosts;
  }
  return out;
}

/// The exact replace body, or null when the entry id or list is not valid.
/// Domains are normalized and de-duplicated, order kept.
Map<String, dynamic>? entryDomainsBody(String entryId, List<String> domains) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(entryId) ||
      domains.length > entryDomainsMax) {
    return null;
  }
  final out = <String>[];
  for (final d in domains) {
    final h = normalizeEntryDomain(d);
    if (h == null) return null;
    if (!out.contains(h)) out.add(h);
  }
  return {'entryId': entryId, 'domains': out};
}

/// A replace counts as confirmed only on HTTP 200 with a JSON object that
/// either says ok:true or echoes exactly the domains that were sent. Anything
/// else is "not confirmed": the server may have applied it, so callers
/// reload before retrying and never retry on their own.
bool entryDomainsConfirmed(int status, String body, List<String> sent) {
  if (status != 200 || body.length > 65536) return false;
  try {
    final j = jsonDecode(body);
    if (j is! Map<String, dynamic>) return false;
    if (j['ok'] == true) return true;
    final d = j['domains'];
    return d is List &&
        d.length == sent.length &&
        [for (var i = 0; i < sent.length; i++) d[i] == sent[i]].every((x) => x);
  } on FormatException {
    return false;
  }
}
