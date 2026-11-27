import 'dart:convert';
import 'dart:js_interop';

import 'package:material_ui/material_ui.dart';

@JS('OTPandaAutofill')
external JSAny? get _autofill;
bool get extensionAutofillAvailable => _autofill.isDefinedAndNotNull;

@JS('OTPandaAutofill.status')
external JSPromise<JSAny?> _status();
@JS('OTPandaAutofill.request')
external JSPromise<JSString> _request();
@JS('OTPandaAutofill.revoke')
external JSPromise<JSAny?> _revoke();

void showExtensionAutofill(BuildContext context) {
  showDialog<void>(context: context, builder: (_) => const _AutofillDialog());
}

class _AutofillDialog extends StatefulWidget {
  const _AutofillDialog();
  @override
  State<_AutofillDialog> createState() => _AutofillDialogState();
}

class _AutofillDialogState extends State<_AutofillDialog> {
  bool busy = true;
  int total = 0, granted = 0;
  String message = '';
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() => busy = true);
    try {
      final raw = (await _status().toDart).dartify();
      final data = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
      if (!mounted) return;
      total = (data['total'] as num?)?.toInt() ?? 0;
      granted =
          (data['grantedCount'] as num?)?.toInt() ??
          (data['granted'] == true ? total : 0);
      if (data['error'] != null &&
          data['error'] != false &&
          data['error'] != '') {
        message = 'Could not load sites. Refresh to try again.';
      }
      if (data['truncated'] == true) {
        message =
            'Showing the first ${data['requested'] ?? 500} of $total matching sites.';
      }
    } catch (_) {
      message = 'Could not load sites. Refresh to try again.';
    }
    if (mounted) setState(() => busy = false);
  }

  void allow() {
    // Start the browser permission request directly in the click handler. The
    // status call above has already loaded the exact candidate origins.
    JSPromise<JSString> pending;
    try {
      pending = _request();
    } catch (_) {
      setState(() => message = 'Autofill is not available in this preview.');
      return;
    }
    setState(() {
      busy = true;
      message = '';
    });
    () async {
      try {
        final result = (await pending.toDart).toDart;
        message = switch (result) {
          'granted' => 'Autofill is on for the sites you allowed.',
          'declined' => 'No new website access was allowed.',
          'none' => 'No matching saved sites yet.',
          'needs-gesture' ||
          'refresh' => 'Refresh, then press Allow autofill again.',
          _ => 'Could not change website access. Refresh and try again.',
        };
      } catch (_) {
        message = 'Could not change website access. Refresh and try again.';
      }
      if (mounted) refresh();
    }();
  }

  Future<void> revoke() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final result = (await _revoke().toDart).dartify();
      message = result == true || result == 'removed' || result == 'none'
          ? 'Autofill website access is off.'
          : 'Could not remove website access. Try again.';
    } catch (_) {
      message = 'Could not remove website access. Try again.';
    }
    if (mounted) refresh();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 400),
    title: const Text('Automatic code autofill'),
    content: SizedBox(
      width: 320,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Allow OTPanda to fill codes automatically on your saved sites. It only fills an empty code field on the page in front of you, never passwords or text you typed. Sites must match the service\'s listed domains or your own associations.',
            ),
            const SizedBox(height: 12),
            Text(
              busy
                  ? 'Loading website access...'
                  : '$granted of $total matching sites allowed.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Your browser asks before adding access. No click is needed for each fill. Signing out pauses autofill but keeps website access. Turn it off here to remove that access.',
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(message),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : refresh,
        child: const Text('Refresh'),
      ),
      TextButton(
        onPressed: busy ? null : revoke,
        child: const Text('Turn off autofill'),
      ),
      FilledButton(
        onPressed: busy || total == 0 ? null : allow,
        child: const Text('Allow autofill'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
