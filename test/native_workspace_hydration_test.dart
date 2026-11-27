import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/offline_totp/native_workspace_snapshot.dart';

import 'product_shell_test.dart' show FakeTransport, routes;

void main() {
  NativeWorkspaceSnapshot snapshot() => NativeWorkspaceSnapshot(
    ownerId: 'o',
    installId: 'i',
    epoch: 2,
    savedAtMs: 1000,
    entries: [const ManagedEntry('a', 'Cached', 'me', true)],
    codes: [
      ReceivedCode.fromJson({
        'entryId': 'a',
        'code': '123456',
        'receivedAt': 1000,
        'expiresAt': 3000,
      }),
    ],
    sources: [],
    unassigned: [],
  );
  test('unlocked cache hydrates immediately, strips management and retains code expiry', () {
    var now = 2000;
    final b = FakeTransport(routes());
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    addTearDown(c.dispose);
    c.hydrateUnlocked(snapshot(), owner: 'o', install: 'i', epoch: 2);
    expect(c.hasLoaded, true);
    expect(c.locallyHydrated, true);
    expect(b.calls, 0);
    expect(c.store.entries.single.manage, false);
    expect(c.store.visibleCodes(now).single.value, '123456');
    now = 3000;
    expect(c.store.visibleCodes(now), isEmpty);
  });
  test('scope mismatch and signed-out state cannot hydrate', () {
    final b = FakeTransport(routes());
    final c = ReadWorkspaceController(bridge: b, clock: () => 2000);
    addTearDown(c.dispose);
    expect(
      () =>
          c.hydrateUnlocked(snapshot(), owner: 'o', install: 'wrong', epoch: 2),
      throwsStateError,
    );
    expect(c.hasLoaded, false);
    b.state = 'idle';
    expect(
      () => c.hydrateUnlocked(snapshot(), owner: 'o', install: 'i', epoch: 2),
      throwsStateError,
    );
  });
  test('clock rollback hides cached codes and clear discards local UI', () {
    final b = FakeTransport(routes());
    final c = ReadWorkspaceController(bridge: b, clock: () => 999);
    addTearDown(c.dispose);
    c.hydrateUnlocked(snapshot(), owner: 'o', install: 'i', epoch: 2);
    expect(c.store.visibleCodes(999), isEmpty);
    c.clear();
    expect(c.locallyHydrated, false);
    expect(c.store.entries, isEmpty);
  });
  test(
    'fresh authenticated read replaces cached display and clears local mode',
    () async {
      final b = FakeTransport(routes());
      final c = ReadWorkspaceController(bridge: b, clock: () => 1000000);
      addTearDown(c.dispose);
      c.hydrateUnlocked(snapshot(), owner: 'o', install: 'i', epoch: 2);
      await c.refresh();
      expect(c.locallyHydrated, false);
      expect(c.store.entries, isEmpty);
    },
  );
}
