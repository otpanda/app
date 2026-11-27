import '../session_contract.dart';

/// Last authenticated UI state only. Never a session, capability grant, seed
/// snapshot or permission to send queued mutations. Hydration preserves expiry.
/// Code values are optional and always checked against the current clock.
final class NativeWorkspaceSnapshot {
  NativeWorkspaceSnapshot({
    required this.ownerId,
    required this.installId,
    required this.epoch,
    required this.savedAtMs,
    required Iterable<ManagedEntry> entries,
    required Iterable<ReceivedCode> codes,
    required Iterable<PrivateSource> sources,
    required Iterable<UnassignedCode> unassigned,
  }) : entries = List.unmodifiable(entries),
       codes = List.unmodifiable(codes),
       sources = List.unmodifiable(sources),
       unassigned = List.unmodifiable(unassigned) {
    if (ownerId.isEmpty ||
        installId.isEmpty ||
        epoch < 0 ||
        savedAtMs < 0 ||
        this.entries.length > 1000 ||
        this.codes.length > 1000 ||
        this.sources.length > 100 ||
        this.unassigned.length > 20) {
      throw const FormatException('Invalid native workspace');
    }
    final ids = this.entries.map((e) => e.id).toSet();
    final sourceIds = this.sources.map((e) => e.id).toSet();
    if (ids.length != this.entries.length ||
        sourceIds.length != this.sources.length ||
        this.codes.any((c) => !ids.contains(c.entryId)) ||
        this.unassigned.any((c) => !sourceIds.contains(c.sourceId))) {
      throw const FormatException('Inconsistent native workspace');
    }
  }
  final String ownerId, installId;
  final int epoch, savedAtMs;
  final List<ManagedEntry> entries;
  final List<ReceivedCode> codes;
  final List<PrivateSource> sources;
  final List<UnassignedCode> unassigned;
  List<ReceivedCode> activeCodes(int now) => now < savedAtMs
      ? const []
      : List.unmodifiable(codes.where((c) => c.active(now)));
  List<UnassignedCode> activeUnassigned(int now) => now < savedAtMs
      ? const []
      : List.unmodifiable(unassigned.where((c) => c.active(now)));

  Map<String, Object?> toJson() => {
    'version': 1,
    'owner': ownerId,
    'install': installId,
    'epoch': epoch,
    'savedAt': savedAtMs,
    'entries': entries
        .map(
          (e) => {
            'entry_id': e.id,
            'label': e.service,
            'account_name': e.account,
            'capabilities': {'manage': e.manage},
            'service_id': e.totp ? 'custom-totp' : e.catalogId ?? 'unknown',
            if (e.catalogId != null) 'catalogId': e.catalogId,
            if (e.issuer != null) 'issuer': e.issuer,
            if (e.expectedDigits != null) 'digits': e.expectedDigits,
            if (e.createdAt != null) 'createdAt': e.createdAt,
          },
        )
        .toList(),
    'codes': codes
        .map(
          (c) => {
            'entryId': c.entryId,
            'code': c.value,
            'receivedAt': c.receivedAt,
            'expiresAt': c.expiresAt,
          },
        )
        .toList(),
    'sources': sources
        .map((s) => {'source_id': s.id, 'kind': s.kind, 'label': s.label})
        .toList(),
    'unassigned': unassigned
        .map(
          (c) => {
            'sourceId': c.sourceId,
            'eventId': c.eventId,
            'code': c.value,
            'receivedAt': c.receivedAt,
            'expiresAt': c.expiresAt,
          },
        )
        .toList(),
  };
  factory NativeWorkspaceSnapshot.fromJson(Map<String, Object?> json) {
    if (json.length != 9 ||
        json['version'] != 1 ||
        json['owner'] is! String ||
        json['install'] is! String ||
        json['epoch'] is! int ||
        json['savedAt'] is! int) {
      throw const FormatException('Invalid native workspace envelope');
    }
    List<T> rows<T>(
      String key,
      int max,
      T Function(Map<String, dynamic>) parse,
    ) {
      final values = json[key];
      if (values is! List || values.length > max) {
        throw const FormatException('Invalid cached rows');
      }
      return values.map((v) {
        if (v is! Map<String, dynamic>) {
          throw const FormatException('Invalid cached row');
        }
        return parse(v);
      }).toList();
    }

    return NativeWorkspaceSnapshot(
      ownerId: json['owner'] as String,
      installId: json['install'] as String,
      epoch: json['epoch'] as int,
      savedAtMs: json['savedAt'] as int,
      entries: rows('entries', 1000, ManagedEntry.fromJson),
      codes: rows('codes', 1000, ReceivedCode.fromJson),
      sources: rows('sources', 100, PrivateSource.fromJson),
      unassigned: rows('unassigned', 20, UnassignedCode.fromJson),
    );
  }
  @override
  String toString() => 'NativeWorkspaceSnapshot(redacted)';
}
