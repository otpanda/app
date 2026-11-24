class AccountEntry {
  final String id, service, account;
  final bool manage;
  final String? serviceId, websiteHost;
  const AccountEntry(
    this.id,
    this.service,
    this.account,
    this.manage, {
    this.serviceId,
    this.websiteHost,
  });
  bool matches(String query) =>
      '$service $account'.toLowerCase().contains(query.trim().toLowerCase());
}

class ActiveCode {
  final String entryId;
  final String value;
  final int receivedAt, expiresAt;
  ActiveCode(this.entryId, this.value, this.receivedAt, this.expiresAt) {
    if (entryId.isEmpty ||
        !RegExp(r'^[A-Za-z0-9-]{4,32}$').hasMatch(value) ||
        receivedAt < 0 ||
        expiresAt <= receivedAt) {
      throw ArgumentError('Invalid code record');
    }
  }
  bool active(int now) => receivedAt <= now && now < expiresAt;
  @override
  String toString() => 'ActiveCode(redacted)';
}
