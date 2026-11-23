import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/organization_contract.dart';

void main() {
  test('cloud snapshot restore is atomic and ranks pins then recent score', () {
    final s = OrganizationStore();
    s.restore(
      {
        'revision': 3,
        'tags': [
          {'id': 't', 'label': 'Work'},
        ],
        'entries': [
          {
            'entryId': 'a',
            'pinned': false,
            'tagIds': ['t'],
          },
          {'entryId': 'b', 'pinned': true, 'tagIds': []},
        ],
        'ranking': [
          {'entryId': 'a', 'score': 5},
        ],
      },
      ['a', 'b', 'c'],
    );
    expect(
      s.orderedEntries(
        ['a', 'b', 'c'],
        order: OrganizationOrder.copyFrequency,
        selectedTagIds: [],
        tagMatch: TagMatch.any,
      ),
      ['b', 'a', 'c'],
    );
    expect(s.document()['entries'], hasLength(3));
    expect(
      () => s.restore(
        {
          'revision': 4,
          'tags': [
            {'id': 't', 'label': 'Work'},
            {'id': 't', 'label': 'Dup'},
          ],
          'entries': [],
          'ranking': [],
        },
        ['a'],
      ),
      throwsArgumentError,
    );
    expect(s.revision, 3);
    expect(s.tags.single.label, 'Work');
    s.clear();
    expect(s.tags, isEmpty);
    expect(s.revision, 0);
  });
  test('rank never introduces a nonaccessible entry or exposes raw counts', () {
    final s = OrganizationStore();
    s.restore(
      {
        'revision': 0,
        'tags': [],
        'entries': [],
        'ranking': [
          {'entryId': 'foreign', 'score': 10},
        ],
      },
      ['mine'],
    );
    expect(
      s.orderedEntries(
        ['mine'],
        order: OrganizationOrder.copyFrequency,
        selectedTagIds: [],
        tagMatch: TagMatch.any,
      ),
      ['mine'],
    );
    expect(s.document().toString(), isNot(contains('score')));
    expect(s.toString(), isNot(contains('mine')));
  });
}
