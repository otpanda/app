import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'session_contract.dart';
import 'sharing_contract.dart';

/// Candidate invite-accept page for the sharing deep link (`#/invite/<token>`).
/// Source only: not in the router or any shell; primary decides placement.
///
/// Accepting is a deliberate tap, never automatic on load, so a forwarded
/// link or a link preview cannot grant access by itself. The token comes
/// from the URL fragment, is sent once in a POST body and is never shown,
/// logged or put back in a URL. The API answers with the granted scope only;
/// it never exposes the owner's identity here.
class SharingAcceptPage extends StatefulWidget {
  final SharingClient? client;
  final Future<InviteAccepted> Function()? acceptPending;
  final bool? pending;
  final bool consumeOnce;
  final String token;

  /// Optional "open codes" action for the success state; the host wires the
  /// destination when it mounts this page.
  final void Function()? onOpenCodes;
  const SharingAcceptPage({
    super.key,
    this.client,
    this.token = '',
    this.acceptPending,
    this.pending,
    this.consumeOnce = false,
    this.onOpenCodes,
  });
  @override
  State<SharingAcceptPage> createState() => _SharingAcceptPageState();
}

final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{32,512}$');

String _scopeText(InviteAccepted a) {
  final scope = switch (a.mode) {
    AccessMode.all => 'All accounts were shared with you.',
    AccessMode.allow => 'Selected accounts were shared with you.',
    AccessMode.deny => 'All except selected accounts were shared with you.',
  };
  return a.canDelegate
      ? '$scope You can also let your own machine profiles read them.'
      : scope;
}

class _SharingAcceptPageState extends State<SharingAcceptPage> {
  /// ready -> accepting -> accepted | failed (failed may retry)
  String state = 'ready';
  InviteAccepted? accepted;
  String error = '';

  bool get tokenValid => widget.pending ?? _tokenPattern.hasMatch(widget.token);

  Future<void> accept() async {
    if (state == 'accepting' || state == 'accepted') return;
    setState(() {
      state = 'accepting';
      error = '';
    });
    try {
      final r =
          await (widget.acceptPending?.call() ??
              widget.client!.acceptInvite(widget.token));
      if (!mounted) return;
      setState(() {
        state = 'accepted';
        accepted = r;
      });
    } on ClientFailure catch (e) {
      if (!mounted) return;
      setState(() {
        state = 'failed';
        error = switch (e.status) {
          404 => 'This invite link is invalid, expired or revoked. Ask the owner for a new one.',
          401 || 403 => 'Sign in, then open the link again to accept.',
          429 => 'Too many attempts. Wait a moment, then try again.',
          _ => 'Could not accept this invite. Try again later.',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        state = 'failed';
        // A network or malformed response can follow a committed accept; the
        // next open of the codes list shows whether it happened.
        error = 'Could not confirm the accept. Check your codes list before trying again; it may already have worked.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Accept shared accounts',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: pal.ink,
                  ),
                ),
                const SizedBox(height: 12),
                ...switch (state) {
                  'accepted' => [
                    Text(
                      key: const Key('accept-success'),
                      "You're in. ${_scopeText(accepted!)} Shared accounts appear in your codes list, read-only. The owner can stop sharing at any time.",
                      style: TextStyle(color: pal.ink),
                    ),
                    if (widget.onOpenCodes != null) ...[
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('accept-done'),
                        onPressed: widget.onOpenCodes,
                        child: const Text('Open codes'),
                      ),
                    ],
                  ],
                  _ when !tokenValid && state == 'ready' => [
                    Text(
                      key: const Key('accept-invalid'),
                      widget.pending == false
                          ? 'Open the original invite link again. This tab no longer holds it. If you already accepted, check your codes.'
                          : 'This invite link is incomplete or damaged. Ask the owner for a new one.',
                    ),
                  ],
                  'failed' when widget.consumeOnce => [
                    Text(
                      error,
                      key: const Key('accept-error'),
                      style: TextStyle(color: pal.ink),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Open the original invite link again to try another acceptance. Check your codes first, since this attempt may already have worked.',
                    ),
                  ],
                  'failed' => [
                    Text(
                      key: const Key('accept-error'),
                      error,
                      style: TextStyle(color: pal.ink),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('accept-retry'),
                      onPressed: accept,
                      child: const Text('Try again'),
                    ),
                  ],
                  _ => [
                    Text(
                      'Accepting adds the shared accounts to your codes list, read-only. The owner can stop sharing at any time.',
                      style: TextStyle(color: pal.ink),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('accept-confirm'),
                      onPressed: state == 'accepting' ? null : accept,
                      child: Text(
                        state == 'accepting' ? 'Accepting…' : 'Accept share',
                      ),
                    ),
                  ],
                },
              ],
            ),
          ),
        ),
      ),
    );
  }
}
