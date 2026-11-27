import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../offline_totp/native_offline_workspace_runtime.dart';
import '../session_contract.dart';

/// A local view, never a fabricated server session. No management or network
/// action is exposed here. Shared cached codes retain their ordinary expiry.
class NativeOfflineWorkspacePage extends StatefulWidget {
  const NativeOfflineWorkspacePage({
    super.key,
    required this.runtime,
    required this.onReconnect,
    this.clock,
  });
  final NativeOfflineWorkspaceRuntime runtime;
  final VoidCallback onReconnect;
  final int Function()? clock;
  @override
  State<NativeOfflineWorkspacePage> createState() => _State();
}

class _State extends State<NativeOfflineWorkspacePage> {
  String query = '';
  Timer? _tick;
  int now() => widget.clock?.call() ?? DateTime.now().millisecondsSinceEpoch;
  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) unawaited(widget.runtime.refreshLocalCodes());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> copy(ReceivedCode code) async {
    // Recheck against the current unlocked view and clock at the action, not
    // only when this tile was built. Lock, owner switch and expiry win.
    if (!code.active(now()) ||
        !widget.runtime.visibleCodes.any(
          (c) => c.entryId == code.entryId && c.value == code.value,
        )) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: code.value));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) {
      final runtime = widget.runtime;
      final snapshot = runtime.snapshot;
      final codes = {for (final c in runtime.visibleCodes) c.entryId: c};
      final entries = snapshot?.entries
          .where(
            (e) => '${e.service} ${e.account}'.toLowerCase().contains(
              query.toLowerCase(),
            ),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: TextField(
            decoration: const InputDecoration(
              hintText: 'Search codes',
              prefixIcon: Icon(Icons.search),
              border: InputBorder.none,
            ),
            onChanged: (value) => setState(() => query = value),
          ),
          actions: [
            IconButton(
              tooltip: 'Reconnect',
              onPressed: widget.onReconnect,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: snapshot == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    runtime.phase == NativeOfflineWorkspacePhase.opening
                        ? 'Opening local codes...'
                        : runtime.phase == NativeOfflineWorkspacePhase.locked
                        ? 'Local codes are locked.'
                        : 'Local codes could not be opened. Your saved data has not been reset.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Icon(Icons.cloud_off_outlined, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Offline. Your own saved authenticator codes still work.',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: entries!.isEmpty
                        ? Center(
                            child: Text(
                              query.isEmpty
                                  ? 'No saved codes yet.'
                                  : 'No matching codes.',
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final entry = entries[index],
                                  code = codes[entries[index].id];
                              return Card(
                                child: ListTile(
                                  leading: Icon(
                                    entry.totp
                                        ? Icons.key_outlined
                                        : Icons.message_outlined,
                                  ),
                                  title: Text(entry.service),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (entry.account.isNotEmpty)
                                        Text(entry.account),
                                      Text(
                                        code?.value ??
                                            (entry.manage && entry.totp
                                                ? 'Local code unavailable'
                                                : 'Connect to refresh this code'),
                                        style: code == null
                                            ? null
                                            : Theme.of(context)
                                                  .textTheme
                                                  .headlineSmall,
                                      ),
                                    ],
                                  ),
                                  trailing: code == null
                                      ? null
                                      : IconButton(
                                          tooltip: 'Copy code',
                                          onPressed: () => copy(code),
                                          icon: const Icon(Icons.copy_outlined),
                                        ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      );
    },
  );
}
