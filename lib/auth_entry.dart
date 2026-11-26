import 'google_button.dart';

import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';
import 'lost_access_page.dart';
import 'recovery_contract.dart';

/// Intended account entry, never a technical session/debug panel.
class AuthEntry extends StatefulWidget {
  final BrowserSessionBridge bridge;
  final String status, message;
  final bool busy;

  /// Native clients always remember the device, so they hide the checkbox.
  final bool showRemember;
  final VoidCallback? onLostAccess;
  final Future<void> Function(Future<void> Function()) run;
  const AuthEntry({
    super.key,
    required this.bridge,
    required this.status,
    required this.message,
    required this.busy,
    this.onLostAccess,
    this.showRemember = true,
    required this.run,
  });
  @override
  State<AuthEntry> createState() => _AuthEntryState();
}

class _AuthEntryState extends State<AuthEntry> {
  final email = TextEditingController(), proof = TextEditingController();
  bool emailOpen = false, remember = true, googleCodeSent = false;
  String? error;
  String? pendingAction;
  Future<void> runAction(
    String action,
    Future<void> Function() operation,
  ) async {
    if (pendingAction != null || widget.busy) return;
    setState(() => pendingAction = action);
    try {
      await widget.run(operation);
    } finally {
      if (mounted) setState(() => pendingAction = null);
    }
  }

  Widget pendingIcon(String action, IconData icon) => pendingAction == action
      ? SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: 'Signing in',
          ),
        )
      : Icon(icon, size: 20);

  @override
  void initState() {
    super.initState();
    if (widget.bridge case AuthEntryBridge b) email.text = b.email;
  }

  @override
  void dispose() {
    email.dispose();
    proof.dispose();
    super.dispose();
  }

  // A nudge that arrives while a request is running is not dropped: it queues
  // exactly one more status read for when the widget is idle again.
  bool recheck = false;
  void nudge(String reason) {
    if (!mounted) return;
    if (widget.busy) {
      recheck = true;
      return;
    }
    recheck = false;
    widget.run(() async {
      // Same status read and completion as the manual button. 'waiting' and
      // 'retry' (a transient failure) change nothing; a definitive refusal or
      // expiry throws and is shown by run.
      await (widget.bridge as AuthEntryBridge).protectionContinue('check');
    });
  }

  @override
  void didUpdateWidget(AuthEntry old) {
    super.didUpdateWidget(old);
    if (old.busy && !widget.busy && recheck) {
      recheck = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => nudge('queued'));
    }
  }

  bool get code => ['email-code', 'code-invalid'].contains(widget.status);
  Future<void> submit() async {
    final address = email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(address)) {
      setState(() => error = 'Enter your email address.');
      return;
    }
    if (code &&
        !RegExp(
          r'^[A-HJ-NP-Z2-9]{8}$',
          caseSensitive: false,
        ).hasMatch(proof.text.replaceAll(' ', '').replaceAll('-', '').trim())) {
      setState(() => error = 'Enter the 8-character code from your email.');
      return;
    }
    if (widget.bridge case AuthEntryBridge b) {
      setState(() => error = null);
      final value = proof.text.trim();
      proof.clear();
      await widget.run(() => b.signupEmail(address, code ? value : ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final google = [
      'google-email',
      'google-link',
      'google-link-only',
    ].contains(status);
    final protected = status == 'extra-verification';
    final authenticating = status == 'authenticating';
    final passkey = ['passkey-ready', 'signup-ready'].contains(status);
    final signup = status == 'signup-ready';
    final form = emailOpen || code || status == 'email-invalid';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          children: [
            const Icon(
              Icons.shield_outlined,
              size: 48,
              color: Color(0xff0a7955),
            ),
            const SizedBox(height: 24),
            Text(
              protected
                  ? 'Verify this device.'
                  : google
                  ? (status == 'google-email'
                        ? 'Verify your email.'
                        : status == 'google-link-only'
                        ? 'Connect Google.'
                        : 'Connect your account.')
                  : signup
                  ? 'Create your passkey.'
                  : form
                  ? 'Create your account.'
                  : code
                  ? 'Check your email.'
                  : 'Welcome to OTPanda.',
              style: const TextStyle(
                fontFamily: 'BricolageGrotesque',
                fontSize: 29,
                fontWeight: FontWeight.w800,
                letterSpacing: -.8,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              protected
                  ? 'Use a passkey, or open Security on your other signed-in device and tap Check for sign-in requests. Compare the match code before approving.'
                  : google
                  ? (status == 'google-email'
                        ? 'One more check: verify ${email.text} to finish signing in with Google.'
                        : status == 'google-link-only'
                        ? 'Verify a passkey to connect ${email.text} to your account. You stay signed in.'
                        : 'An account already uses this email. Verify its passkey to connect Google. No second account will be created.')
                  : signup
                  ? 'Create a passkey to sign in with your fingerprint, face or device PIN.'
                  : code
                  ? 'Enter the code we sent to ${email.text}. Keep using this browser.'
                  : form
                  ? 'Verify your email once, then create a passkey for future sign-in. Email codes are not a login method.'
                  : 'Your codes, wherever you need them. Sign in or get started below.',
              style: const TextStyle(
                fontSize: 16,
                height: 1.5,
                color: Color(0xff52665e),
              ),
            ),
            const SizedBox(height: 28),
            if ((widget.busy || authenticating) && pendingAction == null)
              const LinearProgressIndicator(),
            if (authenticating && pendingAction == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('Complete the passkey prompt on your device.'),
              ),
            if (passkey)
              FilledButton(
                onPressed: widget.busy || pendingAction != null
                    ? null
                    : () => runAction(
                        signup ? 'signup' : 'passkey',
                        widget.bridge.passkey,
                      ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pendingAction == (signup ? 'signup' : 'passkey')) ...[
                      pendingIcon(
                        signup ? 'signup' : 'passkey',
                        Icons.key_outlined,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      signup ? 'Create my passkey' : 'Continue with passkey',
                    ),
                  ],
                ),
              ),
            if (!passkey &&
                !google &&
                !protected &&
                status != 'unsupported' &&
                (!authenticating || pendingAction != null)) ...[
              if (!form) ...[
                GoogleSignInButton(
                  loading: pendingAction == 'google',
                  onPressed: widget.busy || pendingAction != null
                      ? null
                      : () => runAction(
                          'google',
                          () => widget.bridge is AuthEntryBridge
                              ? (widget.bridge as AuthEntryBridge).googleStart(
                                  remember,
                                )
                              : widget.bridge.start('google'),
                        ),
                ),
                const SizedBox(height: 12),
                for (final (label, icon, onTap) in [
                  (
                    'Sign in with a passkey',
                    Icons.key_outlined,
                    () => runAction(
                      'passkey',
                      () => widget.bridge.start('login'),
                    ),
                  ),
                  (
                    'Create account with a passkey',
                    Icons.person_add_alt_1_outlined,
                    () => setState(() => emailOpen = true),
                  ),
                ]) ...[
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                      side: const BorderSide(color: Color(0xff747775)),
                    ),
                    onPressed: widget.busy || pendingAction != null
                        ? null
                        : onTap,
                    icon: pendingIcon(
                      label == 'Sign in with a passkey' ? 'passkey' : 'signup',
                      icon,
                    ),
                    label: Text(label),
                  ),
                  const SizedBox(height: 12),
                ],
              ] else ...[
                TextField(
                  controller: email,
                  enabled: !widget.busy && !code,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email address',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (code) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: proof,
                    enabled: !widget.busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '8-character email code',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: widget.busy ? null : submit,
                  child: Text(
                    code
                        ? 'Verify email and continue'
                        : 'Send verification code',
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: widget.busy
                      ? null
                      : () => setState(() {
                          emailOpen = false;
                          proof.clear();
                          widget.bridge.clear();
                        }),
                  child: const Text('Other ways to continue'),
                ),
              ],
            ],
            if (widget.showRemember &&
                !form &&
                !passkey &&
                !google &&
                !protected &&
                status != 'unsupported' &&
                !authenticating)
              CheckboxListTile(
                value: remember,
                onChanged: widget.busy
                    ? null
                    : (value) => setState(() => remember = value ?? true),
                title: const Text('Remember this device'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            if (google && widget.bridge is AuthEntryBridge) ...[
              if (status == 'google-email') ...[
                if (googleCodeSent) ...[
                  TextField(
                    controller: proof,
                    onSubmitted: (submitted) => widget.run(() async {
                      final value = submitted.trim();
                      proof.clear();
                      await (widget.bridge as AuthEntryBridge).googleContinue(
                        'verify-email',
                        value,
                      );
                    }),
                    enabled: !widget.busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '8-character email code',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: widget.busy
                        ? null
                        : () => widget.run(() async {
                            final value = proof.text.trim();
                            proof.clear();
                            await (widget.bridge as AuthEntryBridge)
                                .googleContinue('verify-email', value);
                          }),
                    child: const Text('Verify and continue'),
                  ),
                ],
                TextButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.run(() async {
                          await (widget.bridge as AuthEntryBridge)
                              .googleContinue('email');
                          if (mounted) setState(() => googleCodeSent = true);
                        }),
                  child: Text(
                    googleCodeSent ? 'Send another code' : 'Email me a code',
                  ),
                ),
              ] else if (status == 'google-link-only') ...[
                FilledButton.icon(
                  onPressed: widget.busy
                      ? null
                      : () => widget.run(
                          () => (widget.bridge as AuthEntryBridge)
                              .googleContinue('link-only'),
                        ),
                  icon: const Icon(Icons.key),
                  label: const Text('Verify with passkey'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.run(
                          () => (widget.bridge as AuthEntryBridge)
                              .googleContinue('link-cancel'),
                        ),
                  child: const Text('Cancel'),
                ),
              ] else
                FilledButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.run(
                          () => (widget.bridge as AuthEntryBridge)
                              .googleContinue('link'),
                        ),
                  child: const Text(
                    'Verify existing account and connect Google',
                  ),
                ),
              if (status != 'google-link-only')
                TextButton(
                  onPressed: widget.busy
                      ? null
                      : () {
                          widget.bridge.clear();
                          setState(() {});
                        },
                  child: const Text('Use another sign-in method'),
                ),
            ],
            if (protected && widget.bridge is AuthEntryBridge) ...[
              Text(
                'Match code: ${(widget.bridge as AuthEntryBridge).pendingLabel}',
              ),
              if (widget.bridge is ProtectionWatchBridge)
                _ProtectionWatcher(
                  key: const ValueKey('pending-protection-watch'),
                  bridge: widget.bridge as ProtectionWatchBridge,
                  onNudge: nudge,
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: widget.busy
                    ? null
                    : () => widget.run(() async {
                        await (widget.bridge as AuthEntryBridge)
                            .protectionContinue('passkey');
                      }),
                child: const Text('Verify with passkey'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.busy
                    ? null
                    : () => widget.run(() async {
                        final result = await (widget.bridge as AuthEntryBridge)
                            .protectionContinue('check');
                        if (result == 'retry' && mounted) {
                          setState(
                            () => error = 'Could not check just now. Try again in a moment.',
                          );
                        }
                        if (result == 'waiting' && mounted) {
                          setState(
                            () => error = 'Waiting for approval. Open Security on your other signed-in device, then check again.',
                          );
                        }
                      }),
                child: const Text('I approved on another device'),
              ),
              TextButton(
                onPressed: widget.busy
                    ? null
                    : () {
                        widget.bridge.clear();
                        setState(() {});
                      },
                child: const Text('Cancel sign-in'),
              ),
            ],
            if (status == 'legacy-account')
              const Text(
                'This Google identity belongs to an earlier OTPanda account. Its data is preserved. Use your existing sign-in method; this account will not be replaced.',
              ),
            if (status == 'existing-account')
              const Padding(
                padding: EdgeInsets.only(top: 18),
                child: Text(
                  'Your account is ready. Use its passkey or linked Google account to sign in.',
                ),
              ),
            if (status == 'logout-incomplete') ...[
              const Padding(
                padding: EdgeInsets.only(top: 18),
                child: Text(
                  'Sign-out could not be confirmed. This browser may still have a server session. Try signing out again before leaving a shared device.',
                ),
              ),
              TextButton(
                onPressed: widget.busy ? null : widget.bridge.logout,
                child: const Text('Try signing out again'),
              ),
            ],
            if (widget.bridge case final RecoveryBridge r
                when r.recoveryAvailable &&
                    !authenticating &&
                    !passkey &&
                    !code)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: widget.busy
                      ? null
                      : widget.onLostAccess ??
                            () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => LostAccessPage(bridge: r),
                              ),
                            ),
                  child: const Text('Lost access to everything?'),
                ),
              ),
            if (status == 'unsupported')
              const Text('Open OTPanda in your browser to continue.'),
            if ([
              'restart',
              'retry',
              'signup-retry-required',
              'check-clock-or-restart',
              'code-invalid',
              'email-invalid',
            ].contains(status))
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Text(
                  status == 'code-invalid'
                      ? 'That code could not be verified. Try again or request a new one.'
                      : status == 'check-clock-or-restart'
                      ? 'Check your device date and time, then try again.'
                      : status == 'email-invalid'
                      ? 'Check your email address and try again.'
                      : 'Sign-in did not finish. You can try again below.',
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(error!),
              ),
            if (widget.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(widget.message),
              ),
          ],
        ),
      ),
    );
  }
}

/// Listens for content-free nudges while a sign-in waits for approval. It only
/// asks the parent to re-read status; the manual button stays as the fallback.
class _ProtectionWatcher extends StatefulWidget {
  const _ProtectionWatcher({
    super.key,
    required this.bridge,
    required this.onNudge,
  });
  final ProtectionWatchBridge bridge;
  final void Function(String reason) onNudge;
  @override
  State<_ProtectionWatcher> createState() => _ProtectionWatcherState();
}

class _ProtectionWatcherState extends State<_ProtectionWatcher> {
  void Function()? stop;
  @override
  void initState() {
    super.initState();
    stop = widget.bridge.protectionWatch(widget.onNudge);
  }

  @override
  void dispose() {
    stop?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
