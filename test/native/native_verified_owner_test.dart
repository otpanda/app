import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_verified_owner.dart';

class _EqualSession {
  @override
  bool operator ==(Object other) => other is _EqualSession;
  @override
  int get hashCode => 0;
}

void main() {
  test('owner is absent until this exact session has been verified', () {
    final fence = NativeVerifiedOwner();
    final old = _EqualSession(), replacement = _EqualSession();
    expect(fence.ownerFor(null), isNull);
    expect(fence.ownerFor(old), isNull);
    fence.bind(old, 'owner-a');
    expect(fence.ownerFor(old), 'owner-a');
    // Matching device fields or value equality cannot inherit authority.
    expect(old == replacement, isTrue);
    expect(fence.ownerFor(replacement), isNull);
    fence.bind(replacement, 'owner-b');
    expect(fence.ownerFor(old), isNull);
    expect(fence.ownerFor(replacement), 'owner-b');
    fence.clear();
    expect(fence.ownerFor(replacement), isNull);
  });
}
