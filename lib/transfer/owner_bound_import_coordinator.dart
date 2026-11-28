import 'dart:convert';

import '../import_recovery_journal.dart';
import '../native/native_device_routes.dart' show DevicePost;
import '../native/native_passkey.dart';
import '../offline_totp/otp_account.dart';
import 'batch_import_saver.dart';
import 'import_review.dart';

/// One session/lock-epoch coordinator shared by Settings and the add scanner.
/// Every new selection is blocked by any prior journal, including a terminal
/// result not yet acknowledged. Only Settings may present startup recovery.
class OwnerBoundImportCoordinator
    implements RecoverableImportSaver, ImportAcknowledgementSource {
  OwnerBoundImportCoordinator({
    required this.deviceId,
    required this.current,
    required this.readSession,
    required this.post,
    required this.passkeys,
    required this.journal,
  });
  final String deviceId;
  final Future<bool> Function() current;
  final Future<({int status, String body})> Function() readSession;
  final DevicePost post;
  final PasskeyAssertionSource passkeys;
  final ImportJournal journal;
  BatchImportSaver? _saver;
  String? _owner;
  bool _preparing = false;
  @override
  bool get atomic => true;
  BatchImportSaver bind(ImportRecoveryBarrier barrier) {
    if (barrier.deviceId != deviceId) throw StateError('identity');
    if (_owner != null && _owner != barrier.ownerId) {
      throw StateError('identity');
    }
    _owner = barrier.ownerId;
    return _saver ??= BatchImportSaver(
      post: post,
      passkeys: passkeys,
      current: current,
      recovery: barrier,
    );
  }

  Future<BatchImportSaver?> _verified() async {
    if (!await current()) return null;
    final r = await readSession();
    if (!await current() || r.status != 200) return null;
    final b = jsonDecode(r.body), owner = b is Map ? b['ownerId'] : null;
    if (owner is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(owner)) {
      return null;
    }
    return bind(
      ImportRecoveryBarrier(
        journal: journal,
        ownerId: owner,
        deviceId: deviceId,
        current: current,
        fence: (body) => post('/v1/manage/totp/batch-outcome', body),
      ),
    );
  }

  @override
  Future<ImportSaveOutcome> save(List<OtpAccount> accounts) async {
    if (_preparing) return ImportSaveOutcome.blocked;
    _preparing = true;
    try {
      final saver = await _verified();
      if (saver == null) return ImportSaveOutcome.blocked;
      return await saver.save(accounts);
    } catch (_) {
      return ImportSaveOutcome.blocked;
    } finally {
      _preparing = false;
    }
  }

  @override
  Future<ImportSaveOutcome> reconcile() async {
    try {
      final saver = await _verified();
      return saver == null
          ? ImportSaveOutcome.unknown
          : await saver.reconcile();
    } catch (_) {
      return ImportSaveOutcome.unknown;
    }
  }

  @override
  Future<bool> Function() captureShownAcknowledgement() {
    final ack = _saver?.captureShownAcknowledgement();
    return () async {
      try {
        if (await _verified() == null) return false;
        return ack == null || await ack();
      } catch (_) {
        return false;
      }
    };
  }

  @override
  Future<bool> acknowledgeShown() async {
    try {
      final saver = await _verified();
      return saver != null && await saver.acknowledgeShown();
    } catch (_) {
      return false;
    }
  }
}
