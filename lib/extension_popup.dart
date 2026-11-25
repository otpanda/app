import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';
import 'main.dart' show ink, muted;
import 'session_contract.dart';

/// Marker for the browser-extension popup bridge. Only that bridge says true.
/// The popup reads the two routes an extension session is allowed
/// (entries, active-codes) and offers nothing else: no add, edit, sources,
/// settings or account screens, and no sign-up or provider choices.
abstract interface class ExtensionPopupBridge {
  bool get extensionPopup;
}

bool isExtensionPopup(Object bridge) =>
    bridge is ExtensionPopupBridge && bridge.extensionPopup;

class ExtensionPopupView extends StatefulWidget {
  final BrowserSessionBridge bridge;
  final int Function()? clock;
  const ExtensionPopupView({super.key, required this.bridge, this.clock});
  @override
  State<ExtensionPopupView> createState() => _ExtensionPopupViewState();
}

class _ExtensionPopupViewState extends State<ExtensionPopupView> {
  bool booting = true, busy = false, loading = false, loaded = false;
  String message = '';
  List<ManagedEntry> entries = const [];
  List<ReceivedCode> codes = const [];
  Timer? ticker, spacing, metaTimer;
  bool entriesDirty = true;
  int lastEntries = 0, lastUnknownFetch = -100000;
  Set<String> unresolved = {};
  int nextRead = 0;
  bool pendingRead = false, liveLost = false;
  void Function()? unsubscribe;
  String copiedFor = '';

  BrowserSessionBridge get bridge => widget.bridge;
  int now() => widget.clock?.call() ?? DateTime.now().millisecondsSinceEpoch;
  bool get signedIn => bridge.status == 'restored';

  @override
  void initState() {
    super.initState();
    () async {
      try {
        await bridge.ready;
      } catch (_) {}
      if (!mounted) return;
      setState(() => booting = false);
      if (signedIn) {
        refresh();
        listen();
      }
    }();
    // Only the visible clock. Data is fetched on open and on every live hint,
    // never on a timer.
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void listen() {
    if (unsubscribe != null || bridge is! RealtimeBridge) return;
    liveLost = true;
    unsubscribe = (bridge as RealtimeBridge).realtimeSubscribe(onHint);
  }

  void stopListening() {
    unsubscribe?.call();
    unsubscribe = null;
    spacing?.cancel();
    metaTimer?.cancel();
    metaTimer = spacing = null;
    pendingRead = false;
  }

  void onHint(String reason) {
    if (!mounted) return;
    if (reason == 'connection-lost' || reason == 'connection-restored') {
      setState(() => liveLost = reason == 'connection-lost');
      return;
    }
    if (reason == 'connect' || reason == 'changed') {
      entriesDirty = true;
      if (reason == 'connect') lastEntries = 0;
      requestRefresh();
    }
  }

  /// One refresh in flight, one trailing refresh, at least 1s between batches.
  void requestRefresh() {
    if (!signedIn) return;
    pendingRead = true;
    drain();
  }

  void drain() {
    if (!pendingRead || !mounted || !signedIn || loading) return;
    final wait = nextRead - now();
    if (wait > 0) {
      spacing ??= Timer(Duration(milliseconds: wait), () {
        spacing = null;
        drain();
      });
      return;
    }
    pendingRead = false;
    refresh().then((_) => drain());
  }

  @override
  void dispose() {
    stopListening();
    ticker?.cancel();
    super.dispose();
  }

  Future<void> signIn() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await bridge.start('extension');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        busy = false;
        message = 'Sign-in did not finish. Try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => busy = false);
    await refresh();
    listen();
  }

  void signOut() {
    stopListening();
    bridge.logout();
    setState(() {
      loaded = false;
      entries = const [];
      codes = const [];
      message = '';
    });
  }

  /// Codes lead on every refresh. Entries (names) are fetched on open/connect,
  /// at most once per 30s after a hint, and at once (still coalesced) when a
  /// code names an entry we do not know. The domains route is never read.
  Future<void> refresh() async {
    if (loading || !signedIn) return;
    setState(() => loading = true);
    nextRead = now() + 2000;
    try {
      final c = await bridge.read('/v1/manage/active-codes');
      if (c.status != 200) throw ClientFailure(c.status, c.retryAfterSeconds);
      final cb = jsonDecode(c.body);
      final raw = [
        for (final j in (cb['records'] as List).cast<Map<String, dynamic>>())
          ReceivedCode.fromJson(j),
      ];
      var es = entries;
      final known = es.map((x) => x.id).toSet();
      // A code for an entry we do not know may fetch names once per 10s, and
      // the same unresolved ids never trigger another fetch until entries
      // change (a revoked or deleted entry must not cost 2 reads per hint).
      final unknownIds = {
        for (final x in raw)
          if (!known.contains(x.entryId)) x.entryId,
      };
      final fresh = unknownIds.difference(unresolved).isNotEmpty;
      final unknown = fresh && now() - lastUnknownFetch >= 10000;
      final due = entriesDirty && now() - lastEntries >= 30000;
      if (!loaded || unknown || due) {
        if (unknown) lastUnknownFetch = now();
        final e = await bridge.read('/v1/manage/entries');
        if (e.status != 200) throw ClientFailure(e.status, e.retryAfterSeconds);
        final eb = jsonDecode(e.body);
        es = [
          for (final j in (eb['entries'] as List).cast<Map<String, dynamic>>())
            ManagedEntry.fromJson(j),
        ];
        lastEntries = now();
        entriesDirty = false;
        unresolved = {
          for (final x in raw)
            if (!es.any((e) => e.id == x.entryId)) x.entryId,
        };
      } else if (entriesDirty || fresh) {
        // Inside a window: one trailing refresh. A new unknown id is waiting on the
        // 10s unknown-entry limit, so its metadata is scheduled at 10s remaining
        // (not 30s) and the new code is not hidden for long.
        final waits = [
          if (fresh) 10000 - (now() - lastUnknownFetch),
          if (entriesDirty) 30000 - (now() - lastEntries),
        ];
        final wait = waits.reduce((x, y) => x < y ? x : y);
        metaTimer ??= Timer(Duration(milliseconds: wait < 0 ? 0 : wait), () {
          metaTimer = null;
          requestRefresh();
        });
      }
      final ids = es.map((x) => x.id).toSet();
      final cs = raw.where((x) => ids.contains(x.entryId)).toList()
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      if (!mounted) return;
      setState(() {
        entries = es;
        codes = cs;
        loaded = true;
        message = '';
      });
    } catch (error) {
      if (!mounted) return;
      final status = error is ClientFailure ? error.status : 0;
      final after = error is ClientFailure ? error.retryAfterSeconds : null;
      if (status == 429) {
        nextRead = now() + ((after ?? 60).clamp(1, 300)) * 1000;
      }
      if (status == 503 || status == 0) nextRead = now() + 10000;
      setState(() {
        message = signedIn
            ? 'Could not load your codes. Retrying shortly.'
            : '';
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> copy(ReceivedCode code) async {
    await Clipboard.setData(ClipboardData(text: code.value));
    if (!mounted) return;
    setState(() => copiedFor = code.entryId);
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => copiedFor = '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = const Text(
      'OTPanda',
      style: TextStyle(
        fontFamily: 'BricolageGrotesque',
        fontWeight: FontWeight.w800,
        color: ink,
      ),
    );
    if (booting) {
      return Scaffold(
        appBar: AppBar(title: title),
        body: const Center(child: Text('Loading...')),
      );
    }
    if (!signedIn) {
      return Scaffold(
        appBar: AppBar(title: title),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Sign in with your OTPanda account',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'BricolageGrotesque',
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'A browser window opens on OTPanda to confirm this '
                'extension. Your codes then appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy ? null : signIn,
                child: Text(busy ? 'Waiting for sign-in...' : 'Sign in'),
              ),
              if (message.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      );
    }
    final names = {for (final e in entries) e.id: e};
    final active = codes.where((c) => c.active(now())).toList();
    return Scaffold(
      appBar: AppBar(
        title: title,
        actions: [
          TextButton(onPressed: signOut, child: const Text('Sign out')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (liveLost && bridge is RealtimeBridge)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Live updates paused. Reconnecting...',
                style: TextStyle(color: muted),
              ),
            ),
          if (message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(message, style: const TextStyle(color: muted)),
            ),
          if (!loaded && message.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('Loading your codes...')),
            ),
          if (loaded && active.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No codes right now. A new code appears here as soon as it '
                'arrives.',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted),
              ),
            ),
          for (final c in active)
            Card(
              child: ListTile(
                title: Text(names[c.entryId]?.service ?? 'Code'),
                subtitle: Text(
                  '${names[c.entryId]?.account ?? ''}\n'
                  '${_left(c.expiresAt - now())} left',
                ),
                isThreeLine: true,
                trailing: TextButton(
                  onPressed: () => copy(c),
                  child: Text(copiedFor == c.entryId ? 'Copied' : c.value),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _left(int ms) {
  final s = (ms / 1000).ceil();
  return s >= 60
      ? '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s'
      : '${s}s';
}
