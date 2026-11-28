import 'owner_bound_import_coordinator.dart';

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../native/native_passkey.dart';
import '../native/native_device_routes.dart' show DevicePost;
import '../import_recovery_journal.dart';
import 'batch_import_saver.dart';
import 'transfer_flow.dart';

/// Inactive composition component. The root must retire it and its saver on
/// session, lock-generation or foreground changes. It never owns offline keys.
class VerifiedImportFlow extends StatefulWidget {
  const VerifiedImportFlow({
    super.key,
    required this.deviceId,
    required this.current,
    required this.readSession,
    required this.post,
    required this.passkeys,
    required this.journal,
    this.readFile,
    this.existing = const {},
    this.onSaved,
    this.onSaver,
    this.coordinator,
  });
  final String deviceId;
  final OwnerBoundImportCoordinator? coordinator;
  final Set<(String?, String)> existing;
  final Future<bool> Function() current;
  final Future<({int status, String body})> Function() readSession;
  final DevicePost post;
  final PasskeyAssertionSource passkeys;
  final ImportJournal journal;
  final Future<String?> Function()? readFile;
  final Future<void> Function()? onSaved;
  final void Function(BatchImportSaver?)? onSaver;
  @override
  State<VerifiedImportFlow> createState() => _VerifiedImportFlowState();
}

class _VerifiedImportFlowState extends State<VerifiedImportFlow> {
  BatchImportSaver? saver;
  String message = 'Checking import recovery...';
  bool checking = false, terminal = false;
  ImportAttempt? shown;
  ImportRecoveryBarrier? barrier;
  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    widget.onSaver?.call(null);
    super.dispose();
  }

  Future<void> _check() async {
    if (checking) return;
    checking = true;
    try {
      if (!await widget.current()) {
        if (mounted) {
          setState(
            () => message = 'Import is paused. Unlock and return to Transfer codes to continue recovery. Nothing has been removed.',
          );
        }
        return;
      }
      final r = await widget.readSession();
      if (!mounted || !await widget.current()) return;
      if (r.status != 200) throw StateError('session_unavailable');
      final body = jsonDecode(r.body);
      final owner = body is Map ? body['ownerId'] : null;
      if (owner is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(owner)) {
        throw const FormatException();
      }
      final recovery = ImportRecoveryBarrier(
        journal: widget.journal,
        ownerId: owner,
        deviceId: widget.deviceId,
        current: widget.current,
        fence: (b) => widget.post('/v1/manage/totp/batch-outcome', b),
      );
      barrier = recovery;
      final result = await recovery.reconcile();
      if (!mounted || !await widget.current()) return;
      switch (result) {
        case ImportRecovery.nothing:
          final ready =
              widget.coordinator?.bind(recovery) ??
              BatchImportSaver(
                post: widget.post,
                passkeys: widget.passkeys,
                current: widget.current,
                recovery: recovery,
              );
          setState(() {
            saver = ready;
            message = '';
            terminal = false;
          });
          widget.onSaver?.call(ready);
        case ImportRecovery.saved:
          shown = await widget.journal.read();
          setState(() {
            message = 'Your previous import was saved.';
            terminal = true;
            saver = null;
          });
          try {
            await widget.onSaved?.call();
          } catch (_) {
            if (mounted) {
              setState(
                () => message = 'Your previous import was saved, but the accounts list could not refresh.',
              );
            }
          }
        case ImportRecovery.fenced:
          shown = await widget.journal.read();
          setState(() {
            message = 'That import attempt was not saved.';
            terminal = true;
            saver = null;
          });
        case ImportRecovery.foreign:
          setState(() {
            message = 'Import recovery belongs to a different signed-in account or device. Return to that account to continue. Nothing has been removed.';
            terminal = false;
            saver = null;
          });
        case ImportRecovery.unknown:
          setState(() {
            message = 'Import recovery could not be verified. New imports are blocked. Your recovery record has been kept.';
            terminal = false;
            saver = null;
          });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          message = 'Import recovery data is unavailable or unreadable. New imports are blocked. Nothing has been removed.';
          saver = null;
          terminal = false;
        });
      }
    } finally {
      checking = false;
    }
  }

  Future<void> _acknowledge() async {
    try {
      final rec = shown;
      if (rec == null ||
          rec.deviceId != widget.deviceId ||
          rec.outcome == 'pending' ||
          !await widget.current()) {
        return;
      }
      // Only a terminal record already presented by _check is acknowledged.
      if (!terminal) return;
      if (!await barrier!.acknowledge(rec)) throw StateError('unavailable');
      if (mounted) {
        setState(() {
          terminal = false;
          message = 'Checking import recovery...';
        });
        await _check();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Could not acknowledge the result. Your recovery record has been kept.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = saver;
    if (s != null) {
      return TransferFlow(
        saver: s,
        existing: widget.existing,
        readFile: widget.readFile,
        onSaved: widget.onSaved,
        onReviewClosed: () async {
          widget.onSaver?.call(null);
          if (mounted) setState(() => saver = null);
          await _check();
        },
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: checking ? null : (terminal ? _acknowledge : _check),
              child: Text(terminal ? 'Got it' : 'Check again'),
            ),
          ],
        ),
      ),
    );
  }
}
