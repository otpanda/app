import 'package:material_ui/material_ui.dart';

import 'recovery_contract.dart';
import 'recovery_panel.dart' show recoveryDate;

/// Steps of the flow. [LostAccessPage.initialStage] lets a host open a step
/// directly (previews, resuming after the wait).
enum LostAccessStage {
  choose,
  startEmail,
  startCode,
  requested,
  finishEmail,
  finishCode,
  done,
  unsure,
}

/// Signed-out "lost all access" flow for the optional email-only escape hatch.
/// Email never signs anyone in: starting only requests a waiting period, and
/// finishing only registers a NEW passkey. Responses never say whether an
/// address has the setting. The wait is enforced by the server.
class LostAccessPage extends StatefulWidget {
  final RecoveryBridge bridge;
  final LostAccessStage initialStage;
  const LostAccessPage({
    super.key,
    required this.bridge,
    this.initialStage = LostAccessStage.choose,
  });
  @override
  State<LostAccessPage> createState() => _LostAccessPageState();
}

class _LostAccessPageState extends State<LostAccessPage> {
  final email = TextEditingController(), code = TextEditingController();
  late LostAccessStage stage = widget.initialStage;
  bool busy = false;
  String? error;
  DateTime? availableAt;

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    super.dispose();
  }

  static final _mail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _code = RegExp(r'^[A-HJ-NP-Z2-9]{8}$', caseSensitive: false);
  String get address => email.text.trim();
  String get clean => code.text.replaceAll(' ', '').replaceAll('-', '').trim();

  Future<void> run(Future<void> Function() action, String failure) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void go(LostAccessStage s) => setState(() {
    stage = s;
    error = null;
    code.clear();
  });

  Future<void> sendStart() async {
    if (!_mail.hasMatch(address)) {
      setState(() => error = 'Enter your email address.');
      return;
    }
    await run(() async {
      await widget.bridge.emailRecoveryStart(address);
      go(LostAccessStage.startCode);
    }, 'Could not send a code. Try again in a moment.');
  }

  Future<void> sendFinish() async {
    if (!_mail.hasMatch(address)) {
      setState(() => error = 'Enter your email address.');
      return;
    }
    await run(() async {
      await widget.bridge.emailRecoverySendCompletionCode(address);
      go(LostAccessStage.finishCode);
    }, 'Could not send a code. Try again in a moment.');
  }

  Future<void> verify() async {
    if (!_code.hasMatch(clean)) {
      setState(() => error = 'Enter the 8-character code from your email.');
      return;
    }
    await run(() async {
      final at = await widget.bridge.emailRecoveryVerify(address, clean);
      availableAt = at;
      go(LostAccessStage.requested);
    }, 'That code did not work. Check it, or start again for a new one.');
  }

  Future<void> complete() async {
    if (!_code.hasMatch(clean)) {
      setState(() => error = 'Enter the 8-character code from your email.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.bridge.emailRecoveryComplete(address, clean);
      if (mounted) go(LostAccessStage.done);
    } on RecoveryRefused {
      if (mounted) {
        setState(
          () => error = 'That request was not accepted. The code may have expired or already been used. If you created a new passkey, try signing in with it. Otherwise request a fresh code.',
        );
      }
    } catch (_) {
      // The reply was lost or unreadable: it may have finished.
      if (mounted) go(LostAccessStage.unsure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(TextEditingController c, String label, {bool upper = false}) =>
      TextField(
        controller: c,
        enabled: !busy,
        autocorrect: false,
        textCapitalization: upper
            ? TextCapitalization.characters
            : TextCapitalization.none,
        keyboardType: upper ? TextInputType.text : TextInputType.emailAddress,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      );

  List<Widget> body() {
    switch (stage) {
      case LostAccessStage.choose:
        return [
          const Text(
            'This only works if you turned on email-only recovery earlier. It always waits 7 days, and you can cancel it from a signed-in passkey device.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => go(LostAccessStage.startEmail),
            child: const Text('Start recovery'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => go(LostAccessStage.finishEmail),
            child: const Text('I already waited 7 days'),
          ),
        ];
      case LostAccessStage.startEmail:
      case LostAccessStage.finishEmail:
        final start = stage == LostAccessStage.startEmail;
        return [
          Text(
            start
                ? 'Enter your account email. If email-only recovery is on for it, we send a code.'
                : 'Enter your account email. If a recovery is ready to finish, we send a fresh code.',
          ),
          const SizedBox(height: 16),
          field(email, 'Email'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : (start ? sendStart : sendFinish),
            child: const Text('Send code'),
          ),
        ];
      case LostAccessStage.startCode:
        return [
          const Text(
            'If that address can recover this way, a code is on its way. Enter it here.',
          ),
          const SizedBox(height: 16),
          field(code, 'Code', upper: true),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : verify,
            child: const Text('Request recovery'),
          ),
        ];
      case LostAccessStage.requested:
        return [
          const Text(
            'Recovery requested',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            availableAt == null
                ? 'You can finish it after 7 days.'
                : 'You can finish it from ${recoveryDate(availableAt!.millisecondsSinceEpoch)}. Come back here and choose "I already waited 7 days". Nothing is opened until then.',
          ),
          const SizedBox(height: 8),
          const Text(
            'If this was not you, sign in on any device with a passkey and cancel it in Recovery.',
          ),
        ];
      case LostAccessStage.finishCode:
        return [
          const Text(
            'Enter the code from your email, then create a new passkey on this device.',
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Finishing signs out every other device and retires your old passkeys, recovery keys and automation tokens. '
                'Your entries, shared entries and linked Google account stay. You then sign in with the new passkey.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          field(code, 'Code', upper: true),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : complete,
            child: const Text('Create new passkey'),
          ),
        ];
      case LostAccessStage.unsure:
        return [
          const Text(
            'We could not confirm the result',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 8),
          const Text(
            'Recovery may have finished. If you created a new passkey, try signing in with it. Otherwise request a fresh code. '
            'If signing in does not work, send a fresh code and try again.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => go(LostAccessStage.finishEmail),
            child: const Text('Send a fresh code'),
          ),
        ];
      case LostAccessStage.done:
        return [
          const Text(
            'Recovery finished',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your new passkey is ready. Sign in with it now. Your old passkeys and devices no longer work.',
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Recover your account')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (busy) const LinearProgressIndicator(),
            ...body(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  key: const Key('lost-error'),
                  style: const TextStyle(color: Color(0xffb3261e)),
                ),
              ),
            if (stage != LostAccessStage.choose &&
                stage != LostAccessStage.done)
              TextButton(
                onPressed: busy ? null : () => go(LostAccessStage.choose),
                child: const Text('Back'),
              ),
          ],
        ),
      ),
    ),
  );
}
