import 'dart:convert';

import 'session_contract.dart';
import 'management_contract.dart';

/// Candidate typed client for the unmounted sharing and machine-profile API.
/// Isolated: nothing imports this file. Paths and bodies mirror the candidate
/// API patch and must be re-checked once the API contract is qualified.
/// Invite and machine tokens are returned once in a response body. They are
/// never put in a URL, a query string or a log line.
enum AccessMode { all, allow, deny }

class InviteCreated {
  final String inviteId;
  final String token;
  final int expiresAt;
  const InviteCreated(this.inviteId, this.token, this.expiresAt);

  /// Fragment form: fragments never reach a server or a Referer header.
  Uri link() => Uri.parse('https://otpanda.github.io/app/#/invite/$token');

  @override
  String toString() => 'InviteCreated($inviteId)';
}

/// Pending invitation metadata only, never a recoverable token or recipient identity.
class PendingInvite {
  final String inviteId;
  final AccessMode mode;
  final bool canDelegate;
  final int createdAt, expiresAt;
  const PendingInvite(
    this.inviteId,
    this.mode,
    this.canDelegate,
    this.createdAt,
    this.expiresAt,
  );
}

class InviteAccepted {
  final AccessMode mode;
  final bool canDelegate;
  const InviteAccepted(this.mode, this.canDelegate);
}

class MachineTokenCreated {
  final String tokenId;
  final String token;
  final int? expiresAt; // null: never expires
  const MachineTokenCreated(this.tokenId, this.token, this.expiresAt);
  @override
  String toString() => 'MachineTokenCreated($tokenId)';
}

/// The terms of a live grant to a contact.
class ContactGrant {
  final AccessMode mode;
  final bool canDelegate;
  const ContactGrant(this.mode, this.canDelegate);
}

/// Someone this owner has already shared with through an accepted invite.
/// Owner-private. [contactRef] is an opaque handle valid only for this owner;
/// the recipient's internal account id is never sent. The user approved
/// showing name, picture and email to the initiating owner.
class SharingContact {
  final String contactRef;
  final int since;
  final bool hidden; // hidden contacts are listed only while a grant is live
  final String? name;
  final String? email;
  final Uri? picture;
  final ContactGrant? grant;
  const SharingContact({
    required this.contactRef,
    required this.since,
    required this.hidden,
    this.name,
    this.email,
    this.picture,
    this.grant,
  });
}

/// Machine token lifetime: one year by default. The owner may choose a custom
/// lifetime or "never expires" (pass [neverExpires]); revocation always works.
const machineTokenDefaultTtl = Duration(days: 365);
const machineTokenMaxTtl = Duration(days: 3650);

/// Metadata only. A token's secret is shown once at creation and never again.
class MachineTokenInfo {
  final String tokenId;
  final int createdAt;
  final int? expiresAt; // null: never expires
  final int? revokedAt;
  const MachineTokenInfo({
    required this.tokenId,
    required this.createdAt,
    this.expiresAt,
    this.revokedAt,
  });
  bool activeAt(int nowMs) =>
      revokedAt == null && (expiresAt == null || expiresAt! > nowMs);
}

class MachineProfileInfo {
  final String profileId, name;
  final AccessMode mode;
  final int createdAt;
  final int? revokedAt;
  final List<String> entryIds;
  final List<MachineTokenInfo> tokens;
  const MachineProfileInfo({
    required this.profileId,
    required this.name,
    required this.mode,
    required this.createdAt,
    required this.revokedAt,
    required this.entryIds,
    required this.tokens,
  });
}

/// An entry a machine profile of this viewer may name: owned, or delegated to
/// them with machine permission.
class MachineEntry {
  final String entryId, label, account;
  final bool owned;
  const MachineEntry(this.entryId, this.label, this.account, this.owned);
}

class SharingClient {
  final ManagementTransport transport;
  const SharingClient(this.transport);

  Future<InviteCreated> createInvite({
    required AccessMode mode,
    required List<String> entryIds,
    required bool canDelegate,
    required int ttlSeconds,
  }) async {
    final r = await _post('/v1/manage/sharing/invite/create', {
      'mode': mode.name,
      'entryIds': _ids(entryIds, mode),
      'canDelegate': canDelegate,
      'ttlSeconds': _int(ttlSeconds),
    });
    return InviteCreated(
      _str(r['inviteId']),
      _str(r['token'], 512),
      _num(r['expiresAt']),
    );
  }

  Future<List<PendingInvite>> listInvites() async {
    final r = await _post('/v1/manage/sharing/invite/list', {}),
        items = r['invites'];
    if (items is! List || items.length > 20) throw const MutationUnconfirmed();
    return items.map((x) {
      if (x is! Map<String, dynamic> || x['canDelegate'] is! bool) {
        throw const MutationUnconfirmed();
      }
      return PendingInvite(
        _str(x['inviteId'], 128),
        _mode(x['mode']),
        x['canDelegate'] as bool,
        _num(x['createdAt']),
        _num(x['expiresAt']),
      );
    }).toList();
  }

  Future<void> revokeInvite(String inviteId) =>
      _ok('/v1/manage/sharing/invite/revoke', {'inviteId': _id(inviteId)});

  Future<InviteAccepted> acceptInvite(String token) async {
    final r = await _post('/v1/manage/sharing/invite/accept', {
      'token': _str(token, 512),
    });
    if (r['ok'] != true || r['canDelegate'] is! bool) {
      throw const MutationUnconfirmed();
    }
    return InviteAccepted(_mode(r['mode']), r['canDelegate'] as bool);
  }

  Future<void> updateGrant({
    required String contactRef,
    required AccessMode mode,
    required List<String> entryIds,
    required bool canDelegate,
  }) => _ok('/v1/manage/sharing/grant/update', {
    'contactRef': _ref(contactRef),
    'mode': mode.name,
    'entryIds': _ids(entryIds, mode),
    'canDelegate': canDelegate,
  });

  /// Share again with a remembered recipient, no new link. The API refuses a
  /// ref that is not one of this owner's visible contacts.
  Future<void> createGrantForContact({
    required String contactRef,
    required AccessMode mode,
    required List<String> entryIds,
    required bool canDelegate,
  }) => _ok('/v1/manage/sharing/grant/create', {
    'contactRef': _ref(contactRef),
    'mode': mode.name,
    'entryIds': _ids(entryIds, mode),
    'canDelegate': canDelegate,
  });

  Future<List<SharingContact>> listContacts() async {
    final r = await _post('/v1/manage/sharing/contacts/list', {});
    final list = r['contacts'];
    if (list is! List || list.length > 200) throw const MutationUnconfirmed();
    return list.map((x) {
      if (x is! Map<String, dynamic>) throw const MutationUnconfirmed();
      final pic = x['picture'];
      final uri = pic is String ? Uri.tryParse(pic) : null;
      final okPic =
          uri != null &&
          uri.scheme == 'https' &&
          uri.host.endsWith('.googleusercontent.com');
      final email = x['email'], name = x['name'], g = x['grant'];
      ContactGrant? grant;
      if (g != null) {
        if (g is! Map<String, dynamic> || g['canDelegate'] is! bool) {
          throw const MutationUnconfirmed();
        }
        grant = ContactGrant(_mode(g['mode']), g['canDelegate'] as bool);
      }
      if (x['hidden'] is! bool) throw const MutationUnconfirmed();
      return SharingContact(
        contactRef: _str(x['contactRef'], 32),
        since: _num(x['since']),
        hidden: x['hidden'] as bool,
        name: name is String && name.length <= 100 ? name : null,
        email: email is String && email.length <= 254 ? email : null,
        picture: okPic ? uri : null,
        grant: grant,
      );
    }).toList();
  }

  /// Hides a contact from suggestions. A live grant is not touched.
  Future<void> removeContact(String contactRef) => _ok(
    '/v1/manage/sharing/contacts/remove',
    {'contactRef': _ref(contactRef)},
  );

  Future<void> revokeGrant(String contactRef) =>
      _ok('/v1/manage/sharing/grant/revoke', {'contactRef': _ref(contactRef)});

  Future<String> createProfile({
    required String name,
    required AccessMode mode,
    required List<String> entryIds,
  }) async {
    final r = await _post('/v1/manage/machine/profile/create', {
      'name': _text(name, 120),
      'mode': mode.name,
      'entryIds': _ids(entryIds, mode),
    });
    return _str(r['profileId']);
  }

  Future<List<MachineProfileInfo>> listProfiles() async {
    final r = await _post('/v1/manage/machine/profiles/list', {});
    final list = r['profiles'];
    if (list is! List || list.length > 100) throw const MutationUnconfirmed();
    return list.map((x) {
      if (x is! Map<String, dynamic>) throw const MutationUnconfirmed();
      final ids = x['entryIds'], toks = x['tokens'];
      if (ids is! List || toks is! List || toks.length > 1000) {
        throw const MutationUnconfirmed();
      }
      return MachineProfileInfo(
        profileId: _str(x['profileId']),
        name: _str(x['name'], 120),
        mode: _mode(x['mode']),
        createdAt: _num(x['createdAt']),
        revokedAt: x['revokedAt'] == null ? null : _num(x['revokedAt']),
        entryIds: [for (final i in ids) _str(i)],
        tokens: [
          for (final t in toks)
            if (t is Map<String, dynamic>)
              MachineTokenInfo(
                tokenId: _str(t['tokenId']),
                createdAt: _num(t['createdAt']),
                expiresAt: t['expiresAt'] == null ? null : _num(t['expiresAt']),
                revokedAt: t['revokedAt'] == null ? null : _num(t['revokedAt']),
              )
            else
              throw const MutationUnconfirmed(),
        ],
      );
    }).toList();
  }

  Future<List<MachineEntry>> listMachineEntries() async {
    final r = await _post('/v1/manage/machine/entries/list', {});
    final list = r['entries'];
    if (list is! List || list.length > 500) throw const MutationUnconfirmed();
    return [
      for (final x in list)
        if (x is Map<String, dynamic> && x['owned'] is bool)
          MachineEntry(
            _str(x['entryId']),
            _str(x['label'], 120),
            x['account'] is String ? x['account'] as String : '',
            x['owned'] as bool,
          )
        else
          throw const MutationUnconfirmed(),
    ];
  }

  /// Revokes one token. The profile and its other tokens keep working.
  Future<void> revokeToken(String profileId, String tokenId) => _ok(
    '/v1/manage/machine/token/revoke',
    {'profileId': _id(profileId), 'tokenId': _id(tokenId)},
  );

  /// Revokes the profile and every token it has.
  Future<void> revokeProfile(String profileId) =>
      _ok('/v1/manage/machine/profile/revoke', {'profileId': _id(profileId)});

  Future<MachineTokenCreated> createMachineToken(
    String profileId, {
    Duration? ttl = machineTokenDefaultTtl,
    bool neverExpires = false,
  }) async {
    if (neverExpires && ttl != machineTokenDefaultTtl) {
      throw ArgumentError('Choose a lifetime or never expires, not both');
    }
    final effective = neverExpires ? null : ttl;
    if (!neverExpires &&
        (effective == null ||
            effective < const Duration(seconds: 1) ||
            effective > machineTokenMaxTtl)) {
      throw ArgumentError('Invalid token lifetime');
    }
    final r = await _post('/v1/manage/machine/token/create', {
      'profileId': _id(profileId),
      'ttlSeconds': effective?.inSeconds,
    });
    return MachineTokenCreated(
      _str(r['tokenId']),
      _str(r['token'], 512),
      r['expiresAt'] == null ? null : _num(r['expiresAt']),
    );
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    SessionResponse response;
    try {
      response = await transport.request(path, 'POST', body);
    } catch (_) {
      throw const MutationUnconfirmed();
    }
    final s = response.status;
    if (s == 400 || s == 401 || s == 403 || s == 404 || s == 429) {
      throw ClientFailure(s);
    }
    if (s != 200 || response.body.length > 65536) {
      throw const MutationUnconfirmed();
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    } catch (_) {
      throw const MutationUnconfirmed();
    }
  }

  Future<void> _ok(String path, Map<String, Object?> body) async {
    if ((await _post(path, body))['ok'] != true) {
      throw const MutationUnconfirmed();
    }
  }
}

final _refPattern = RegExp(r'^[0-9a-f]{32}$');
String _ref(String v) {
  if (!_refPattern.hasMatch(v)) throw ArgumentError('Invalid contact');
  return v;
}

final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,256}$');
String _id(String v) {
  if (!_idPattern.hasMatch(v)) throw ArgumentError('Invalid identifier');
  return v;
}

/// "all" carries no entries; allow and deny need at least one.
List<String> _ids(List<String> v, AccessMode mode) {
  if (v.length > 500) throw ArgumentError('Too many entries');
  if (mode == AccessMode.all && v.isNotEmpty) {
    throw ArgumentError('Full access takes no entry list');
  }
  if (mode == AccessMode.allow && v.isEmpty) {
    throw ArgumentError('Choose at least one entry');
  }
  return v.map(_id).toList();
}

int _int(int v) {
  if (v <= 0) throw ArgumentError('Invalid lifetime');
  return v;
}

String _text(String value, int max) {
  final t = value.trim();
  if (t.isEmpty || t.length > max) throw ArgumentError('Invalid input');
  return t;
}

String _str(Object? v, [int max = 256]) {
  if (v is! String || v.isEmpty || v.length > max) {
    throw const MutationUnconfirmed();
  }
  return v;
}

int _num(Object? v) {
  if (v is! int) throw const MutationUnconfirmed();
  return v;
}

AccessMode _mode(Object? v) => AccessMode.values.firstWhere(
  (m) => m.name == v,
  orElse: () => throw const MutationUnconfirmed(),
);
