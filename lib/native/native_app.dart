import 'package:material_ui/material_ui.dart';

import '../branding.dart';
import '../app_theme.dart';
import '../theme_controller.dart';
import '../auth_entry.dart';
import '../browser_session_contract.dart';
import '../lost_access_page.dart';
import '../recovery_contract.dart';
import 'native_session.dart';

/// Native shell: renews at start, then shows sign-in, an honest signed-in
/// page, or the offline / sign-in-required states. Account data screens are
/// not native yet, so signed-in shows status and Sign out only.
class NativeApp extends StatelessWidget {
  const NativeApp({
    super.key,
    required this.controller,
    required this.googleAvailable,
    this.version = '',
    this.signedInBuilder,
    this.authBridge,
    this.appWrapper,
    this.navigatorObservers = const [],
    this.themeController,
  });
  final ThemeController? themeController;
  final List<NavigatorObserver> navigatorObservers;
  final Widget Function(BuildContext, Widget)? appWrapper;
  final NativeSessionController controller;
  final bool googleAvailable;
  final String version;

  /// The shared sign-in screen's bridge. When set, signed-out phases show the
  /// same AuthEntry screen as web.
  final BrowserSessionBridge? authBridge;

  /// Replaces the status page when signed in (the shared account UI).
  final WidgetBuilder? signedInBuilder;

  @override
  Widget build(BuildContext context) => ThemeScope(
    controller: themeController ?? appThemeController,
    builder: (context, light, dark, mode) => MaterialApp(
      title: 'OTPanda',
      navigatorObservers: navigatorObservers,
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      themeMode: mode,
      builder: (context, child) => appWrapper?.call(context, child!) ?? child!,
      home: NativeSessionPage(
        controller: controller,
        googleAvailable: googleAvailable,
        version: version,
        signedInBuilder: signedInBuilder,
        authBridge: authBridge,
      ),
    ),
  );
}

class NativeSessionPage extends StatefulWidget {
  const NativeSessionPage({
    super.key,
    required this.controller,
    required this.googleAvailable,
    this.version = '',
    this.signedInBuilder,
    this.authBridge,
  });
  final NativeSessionController controller;
  final bool googleAvailable;
  final String version;
  final WidgetBuilder? signedInBuilder;
  final BrowserSessionBridge? authBridge;
  @override
  State<NativeSessionPage> createState() => _State();
}

class _State extends State<NativeSessionPage> {
  bool busy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.start();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // Only the signup stages change the shared screen; everything else is the
  // plain welcome screen.
  String _authStatus(String s) =>
      const {
        'email-code',
        'code-invalid',
        'signup-ready',
        'google-link',
      }.contains(s)
      ? s
      : 'sign-in-required';

  String? _error(String? k) => switch (k) {
    'signup_existing' =>
      'An account already uses this email. Sign in with your passkey instead.',
    'signup_unconfirmed' => 'Sign-up did not finish. If your account was created, sign in with your passkey.',
    'passkey_failed' => 'The passkey could not be created. Try again.',
    null => null,
    'cancelled' => null,
    'rate_limited' => 'Too many attempts. Try again in a minute.',
    'unavailable' => 'OTPanda could not be reached. Try again later.',
    'network' => 'No connection. Check your network and try again.',
    'busy' => null,
    'continue_required' => null,
    'google_link_unconfirmed' =>
      'Google may now be connected. Sign in with your passkey.',
    'browser_required' => 'This account needs sign-in in the browser.',
    _ => 'Sign-in did not complete. Try again.',
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      if (c.phase == NativeSessionPhase.signedIn &&
          widget.signedInBuilder != null) {
        return widget.signedInBuilder!(context);
      }
      final err = _error(c.lastError);
      final shared = widget.authBridge;
      if (shared != null &&
          (c.phase == NativeSessionPhase.signedOut ||
              c.phase == NativeSessionPhase.signInRequired)) {
        return Scaffold(
          appBar: AppBar(title: const Text('OTPanda')),
          body: AuthEntry(
            bridge: shared,
            status: _authStatus(shared.status),
            message: err ?? '',
            busy: busy,
            showRemember: false,
            onLostAccess:
                shared is RecoveryBridge &&
                    (shared as RecoveryBridge).recoveryAvailable
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('OTPanda')),
                        body: LostAccessPage(
                          bridge: shared as RecoveryBridge,
                          onExit: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
                  )
                : null,
            run: _run,
          ),
        );
      }
      final (title, body) = switch (c.phase) {
        NativeSessionPhase.unknown => ('OTPanda', 'Checking your session...'),
        NativeSessionPhase.signedIn => (
          'You are signed in',
          'Your account screens are not on this device yet. Open OTPanda in the browser for them.',
        ),
        NativeSessionPhase.signInRequired => (
          'Sign in again',
          'This device could not renew its session. Sign in to continue.',
        ),
        NativeSessionPhase.offline => (
          'Cannot reach OTPanda',
          'Your session is kept on this device. Try again when you are online.',
        ),
        NativeSessionPhase.signedOut => (
          'Sign in to OTPanda',
          'Use your Google account or sign in with the browser.',
        ),
      };
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Image.memory(
                      ottyImage,
                      width: 72,
                      height: 72,
                      semanticLabel: 'OTPanda mascot',
                    ),
                    const SizedBox(height: 20),
                    Text(
                      title,
                      style: TextStyle(
                        color: context.pal.ink,
                        fontFamily: 'BricolageGrotesque',
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      body,
                      style: TextStyle(
                        color: context.pal.muted,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (c.phase == NativeSessionPhase.signedOut ||
                        c.phase == NativeSessionPhase.signInRequired) ...[
                      if (widget.googleAvailable)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            key: const Key('native-google'),
                            style: FilledButton.styleFrom(
                              backgroundColor: context.pal.brand,
                            ),
                            onPressed: busy
                                ? null
                                : () => _run(c.signInWithGoogle),
                            child: const Text('Continue with Google'),
                          ),
                        ),
                      if (widget.googleAvailable) const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child:
                            (widget.googleAvailable
                            ? OutlinedButton.new
                            : FilledButton.new)(
                              key: const Key('native-browser'),
                              onPressed: busy
                                  ? null
                                  : () => _run(c.signInWithBrowser),
                              child: const Text('Sign in with browser'),
                            ),
                      ),
                    ],
                    if (c.phase == NativeSessionPhase.offline)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          key: const Key('native-retry'),
                          style: FilledButton.styleFrom(
                            backgroundColor: context.pal.brand,
                          ),
                          onPressed: busy ? null : () => _run(c.start),
                          child: const Text('Try again'),
                        ),
                      ),
                    if (c.phase == NativeSessionPhase.signedIn)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          key: const Key('native-signout'),
                          onPressed: busy ? null : () => _run(c.signOut),
                          child: const Text('Sign out'),
                        ),
                      ),
                    if (err != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: context.pal.line),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          err,
                          key: const Key('native-error'),
                          style: TextStyle(
                            color: context.pal.ink,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                    if (widget.version.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text(
                        'Version ${widget.version}',
                        style: TextStyle(
                          color: context.pal.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
