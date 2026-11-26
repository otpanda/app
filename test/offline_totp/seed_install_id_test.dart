import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/seed_install_id.dart';

class Store implements SeedInstallIdStore {
  String? saved;
  String? winner;
  bool fail = false;
  int reads = 0, writes = 0;
  Completer<void>? pause;
  @override
  Future<String?> read() async {
    reads++;
    await pause?.future;
    if (fail) throw StateError('unavailable');
    return saved;
  }

  @override
  Future<String> createIfAbsent(String candidate) async {
    writes++;
    if (fail) throw StateError('unavailable');
    return saved ??= winner ?? candidate;
  }
}

void main() {
  test(
    'new random id singleflight, persisted and stable across restart',
    () async {
      final s = Store()..pause = Completer<void>();
      final ids = SeedInstallId(s, random: Random(1));
      final a = ids.get(), b = ids.get();
      s.pause!.complete();
      expect(await a, await b);
      expect(await a, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(s.reads, 1);
      expect(s.writes, 1);
      expect(await SeedInstallId(s).get(), await a);
      expect(s.writes, 1);
    },
  );
  test('valid create-if-absent winner wins race', () async {
    final s = Store()..winner = 'W' * 43;
    expect(await SeedInstallId(s).get(), 'W' * 43);
  });
  test(
    'corrupt persisted id is not overwritten or silently replaced',
    () async {
      final s = Store()..saved = 'bad';
      await expectLater(SeedInstallId(s).get(), throwsFormatException);
      expect(s.writes, 0);
      expect(s.saved, 'bad');
    },
  );
  test(
    'storage failure retries later, never falls back to memory-only id',
    () async {
      final s = Store()..fail = true;
      final ids = SeedInstallId(s);
      await expectLater(ids.get(), throwsStateError);
      expect(s.writes, 0);
      s.fail = false;
      expect(await ids.get(), isNotEmpty);
      expect(s.writes, 1);
    },
  );
  test('corrupt create reply is not accepted', () async {
    final s = Store()..winner = 'bad';
    await expectLater(SeedInstallId(s).get(), throwsFormatException);
  });
}
