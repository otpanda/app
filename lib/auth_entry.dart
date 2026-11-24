import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';

/// Intended account entry, never a technical session/debug panel.
class AuthEntry extends StatefulWidget {
  final BrowserSessionBridge bridge;
  final String status, message;
  final bool busy;
  final Future<void> Function(Future<void> Function()) run;
  const AuthEntry({
    super.key,
    required this.bridge,
    required this.status,
    required this.message,
    required this.busy,
    required this.run,
  });
  @override
  State<AuthEntry> createState() => _AuthEntryState();
}

class _AuthEntryState extends State<AuthEntry> {
  final email = TextEditingController(), proof = TextEditingController();
  bool emailOpen = false, remember = true, googleCodeSent = false;
  String? error;
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
    final google = ['google-email', 'google-link'].contains(status);
    final protected = status == 'extra-verification';
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
                        : 'Connect your account.')
                  : signup
                  ? 'Make yourself at home.'
                  : code
                  ? 'Check your email.'
                  : 'Welcome to OTPanda.',
              style: const TextStyle(
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
                        : 'An account already uses this email. Verify its passkey to connect Google. No second account will be created.')
                  : signup
                  ? 'Create a passkey to sign in with your fingerprint, face or device PIN.'
                  : code
                  ? 'Enter the code we sent to ${email.text}. Keep using this browser.'
                  : 'Your codes, wherever you need them. Sign in or get started below.',
              style: const TextStyle(
                fontSize: 16,
                height: 1.5,
                color: Color(0xff52665e),
              ),
            ),
            const SizedBox(height: 28),
            if (widget.busy) const LinearProgressIndicator(),
            if (passkey)
              FilledButton(
                onPressed: widget.busy
                    ? null
                    : () => widget.run(widget.bridge.passkey),
                child: Text(
                  signup ? 'Create my passkey' : 'Continue with passkey',
                ),
              ),
            if (!passkey &&
                !google &&
                !protected &&
                status != 'unsupported') ...[
              if (!form) ...[
                FilledButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.run(
                          () => widget.bridge is AuthEntryBridge
                              ? (widget.bridge as AuthEntryBridge).googleStart(
                                  remember,
                                )
                              : widget.bridge.start('google'),
                        ),
                  child: const Text('Continue with Google'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.run(() => widget.bridge.start('login')),
                  child: const Text('Use a passkey'),
                ),
                const SizedBox(height: 18),
                TextButton(
                  onPressed: widget.busy
                      ? null
                      : () => setState(() => emailOpen = true),
                  child: const Text('Continue with email'),
                ),
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
                  child: Text(code ? 'Continue' : 'Email me a code'),
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
            if (!form &&
                !passkey &&
                !google &&
                !protected &&
                status != 'unsupported')
              CheckboxListTile(
                value: remember,
                onChanged: widget.busy
                    ? null
                    : (value) => setState(() => remember = value ?? true),
                title: const Text('Remember this device for Google'),
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
            const SizedBox(height: 28),
            const Text(
              'No passwords. No SMS codes.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xff52665e)),
            ),
          ],
        ),
      ),
    );
  }
}
