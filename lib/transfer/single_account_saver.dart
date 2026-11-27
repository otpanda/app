import '../browser_session_contract.dart';
import '../offline_totp/otp_account.dart';
import '../offline_totp/otpauth_uri.dart';
import 'import_review.dart';

/// Saves exactly one account through the existing passkey-confirmed add. One
/// account is one confirmation and one commit, so it is atomic. More than one
/// is refused: a batch needs a real atomic saver (see the batch-import
/// contract), never a loop of single adds with partial commits.
final class SingleAccountSaver implements ImportSaver {
  SingleAccountSaver(this.bridge);
  final TotpManagementBridge bridge;
  @override
  bool get atomic => true;

  @override
  Future<ImportSaveOutcome> save(List<OtpAccount> accounts) async {
    if (accounts.length != 1) throw ArgumentError('exactly one account');
    final a = accounts.single;
    try {
      await bridge.addTotp(
        a.issuer ?? a.accountName,
        a.accountName,
        encodeOtpauthUri(a),
      );
      return ImportSaveOutcome.saved;
    } catch (e) {
      final m = e.toString();
      if (m.contains('cancelled')) return ImportSaveOutcome.cancelled;
      // The server may have committed before the reply was lost.
      return ImportSaveOutcome.unknown;
    }
  }
}
