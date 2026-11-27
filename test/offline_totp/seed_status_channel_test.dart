import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/seed_status_channel.dart';
import 'package:otpanda_client/offline_totp/seed_status_coordinator.dart';

import 'seed_status_coordinator_test.dart' show Transport;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('inactive-seed-status-test');
  final calls = <MethodCall>[];
  final fixture = jsonDecode(
    File('test/fixtures/seed_status_native_v10.json').readAsStringSync(),
  ) as Map;
  String outcome = 'purged';
  Object discovery = {
    'owners': [
      {'owner': 'healthy', 'keyId': 'keyA', 'pending': false},
      {'owner': 'pending', 'keyId': null, 'pending': true},
    ],
    'unreadable': 1,
    'complete': false,
  };
  setUp(() {
    calls.clear();
    discovery = fixture['discovery'];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'syncRetryPending' => {
              'keyDeletesPending': 0,
              'purgesOwed': 0,
              'unreadableOwners': 0,
            },
            'syncDiscoverOwners' => discovery,
            'syncStatusKeyId' => 'keyA',
            'syncStatusSign' => 'A' * 86,
            'syncStatusApply' =>
              (fixture['outcomes'] as Map)[outcome] ?? {'outcome': outcome},
            _ => throw MissingPluginException(),
          };
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'v10 discovery rows use one snapshot and retain incomplete progress',
    () async {
      final t = Transport();
      final sweep = await SeedStatusCoordinator(
        t,
        SeedStatusChannel(channel),
      ).checkAll();
      expect(sweep.incomplete, true);
      expect(sweep.results, {'healthy': SeedStatusResult.purged});
      expect(t.calls, 2);
      expect(calls.where((c) => c.method == 'syncDiscoverOwners').length, 1);
      expect(
        calls.where((c) => (c.arguments as Map)['owner'] == 'pending'),
        isEmpty,
      );
      expect(calls.firstWhere((c) => c.method == 'syncStatusSign').arguments, {
        'owner': 'healthy',
        'keyId': 'keyA',
        'challenge': 'A' * 43,
        'expiresAt': 1800000120000,
      });
    },
  );
  test('closed lowercase outcomes map without false purge', () async {
    for (final pair in {
      'pending': SeedStatusResult.retry,
      'unreadable': SeedStatusResult.retry,
      'noop': SeedStatusResult.superseded,
      'unexpected': SeedStatusResult.retry,
      'purged': SeedStatusResult.purged,
    }.entries) {
      outcome = pair.key;
      expect(
        await SeedStatusCoordinator(
          Transport(),
          SeedStatusChannel(channel),
        ).check('owner'),
        pair.value,
      );
    }
  });
  test('malformed discovery is incomplete, never success', () async {
    discovery = {'owners': [], 'unreadable': -1, 'complete': true};
    final sweep = await SeedStatusCoordinator(
      Transport(),
      SeedStatusChannel(channel),
    ).checkAll();
    expect(sweep.incomplete, true);
    expect(sweep.results, isEmpty);
  });
}
