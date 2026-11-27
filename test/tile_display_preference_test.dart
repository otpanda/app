import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/tile_display_preference.dart';

class Store implements TileDisplayStore {
  bool saved = false, fail = false;
  Completer<bool>? read;
  final writes = <bool>[];
  @override
  Future<bool> showTags() async => read == null ? saved : await read!.future;
  @override
  Future<void> setShowTags(bool enabled) async {
    writes.add(enabled);
    if (fail) throw StateError('unavailable');
    saved = enabled;
  }
}

void main() {
  test('off default, explicit saved choice restored on same device', () async {
    final s = Store(), p = TileDisplayPreference(Store());
    expect(p.showTags, false);
    final a = TileDisplayPreference(s);
    await a.setShowTags(true);
    final b = TileDisplayPreference(s);
    await b.load();
    expect(b.showTags, true);
    expect(TileDisplayPreference(Store()).showTags, false);
  });
  test('late preference load cannot undo a newer explicit choice', () async {
    final s = Store()..read = Completer<bool>();
    final p = TileDisplayPreference(s);
    final load = p.load();
    await p.setShowTags(true);
    s.read!.complete(false);
    await load;
    expect(p.showTags, true);
  });
  test('rapid saves serialize and last choice wins', () async {
    final s = Store(), p = TileDisplayPreference(Store());
    final a = TileDisplayPreference(s);
    await Future.wait([a.setShowTags(true), a.setShowTags(false)]);
    expect(s.writes, [true, false]);
    expect(a.showTags, false);
    expect(p.showTags, false);
  });
  test('failed save not falsely applied, later save works', () async {
    final s = Store()..fail = true;
    final p = TileDisplayPreference(s);
    await expectLater(p.setShowTags(true), throwsStateError);
    expect(p.showTags, false);
    s.fail = false;
    await p.setShowTags(true);
    expect(p.showTags, true);
  });
}
