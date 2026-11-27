import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/detail_routes.dart';

void main() {
  test('stable IDs round trip without slash ambiguity', () {
    expect(parseDetailRoute(accountDetailRoute('a/b +é'))!.accountId, 'a/b +é');
    final route = parseDetailRoute(
      unassignedDetailRoute('src/one', 'event#2'),
    )!;
    expect(route.sourceId, 'src/one');
    expect(route.eventId, 'event#2');
  });
  test('malformed noncanonical and control IDs do not resolve', () {
    for (final r in [
      'accounts/',
      'accounts/=',
      'accounts/YQ==',
      'accounts/YQ/',
      'accounts/AA',
      'unassigned-details/YQ',
      'garbage',
    ]) {
      expect(parseDetailRoute(r), isNull, reason: r);
    }
  });
}
