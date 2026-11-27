/// Private cloud organization snapshot, separate from code/source metadata.
/// Transport and successful-copy submission are owned by the account page.
///
/// Create one store for the signed-in viewer, not the owner of a shared entry.
/// Platform integration clears on logout/account switch. Preferences grant no access.
library;

enum OrganizationOrder { original, copyFrequency }

enum TagMatch { any, all }

final class PersonalTag {
  final String id, label;
  const PersonalTag._(this.id, this.label);
  @override
  String toString() => 'PersonalTag(redacted)';
}

final class EntryOrganization {
  final bool pinned;
  final Set<String> tagIds;
  EntryOrganization._(this.pinned, Iterable<String> tags)
    : tagIds = Set.unmodifiable(tags);
  @override
  String toString() => 'EntryOrganization(redacted)';
}

final class OrganizationStore {
  static const maxTags = 100;
  static const maxEntries = 1000;
  final Map<String, PersonalTag> _tags = {};
  final Map<String, _Preferences> _entries = {};

  List<PersonalTag> get tags => List.unmodifiable(_tags.values);

  /// Refresh the current accessible-entry catalog. Entries without active codes
  /// remain eligible. Removed/inaccessible entries lose their local preferences.
  /// Input is fully validated before any mutation. Never pass service IDs here.
  void reconcileEntries(Iterable<String> entryIds) {
    final ids = entryIds.toList();
    if (ids.length > maxEntries || ids.toSet().length != ids.length) {
      throw ArgumentError('Invalid entry catalog');
    }
    for (final id in ids) {
      _identifier(id);
    }
    final known = ids.toSet();
    _entries.removeWhere((id, _) => !known.contains(id));
    for (final id in ids) {
      _entries.putIfAbsent(id, _Preferences.new);
    }
  }

  void createTag(String tagId, String label) {
    _identifier(tagId);
    final clean = _label(label);
    if (_tags.containsKey(tagId) || _tags.length >= maxTags) {
      throw ArgumentError('Cannot create tag');
    }
    _uniqueLabel(clean);
    _tags[tagId] = PersonalTag._(tagId, clean);
  }

  void renameTag(String tagId, String label) {
    _tag(tagId);
    final clean = _label(label);
    _uniqueLabel(clean, except: tagId);
    _tags[tagId] = PersonalTag._(tagId, clean);
  }

  void deleteTag(String tagId) {
    _tag(tagId);
    _tags.remove(tagId);
    for (final entry in _entries.values) {
      entry.tags.remove(tagId);
    }
  }

  void setTags(String entryId, Iterable<String> tagIds) {
    final entry = _entry(entryId);
    final ids = tagIds.toSet();
    for (final id in ids) {
      _tag(id);
    }
    entry.tags = ids;
  }

  void setPinned(String entryId, bool pinned) =>
      _entry(entryId).pinned = pinned;

  EntryOrganization preferencesFor(String entryId) {
    final entry = _entry(entryId);
    return EntryOrganization._(entry.pinned, entry.tags);
  }

  final Map<String, double> _scores = {};
  final Map<String, int> _lastUsedDays = {};
  double scoreFor(String id) => _scores[id] ?? 0;

  /// UTC day start only, bounded by the server's 90-day history.
  int? lastUsedDayFor(String id) => _lastUsedDays[id];
  int revision = 0;
  Map<String, dynamic> document() => {
    'tags': [
      for (final t in tags) {'id': t.id, 'label': t.label},
    ],
    'entries': [
      for (final e in _entries.entries)
        {
          'entryId': e.key,
          'pinned': e.value.pinned,
          'tagIds': e.value.tags.toList(),
        },
    ],
  };

  /// Compare and atomically replace a locally edited document. Concurrent unseen
  /// changes refuse the whole edit; validation happens before any mutation.
  bool applyDraft(Map<String, dynamic> expected, Map<String, dynamic> draft) {
    bool same(Object? a, Object? b) {
      if (a is Map && b is Map) {
        return a.length == b.length &&
            a.keys.every((k) => b.containsKey(k) && same(a[k], b[k]));
      }
      if (a is List && b is List) {
        return a.length == b.length &&
            List.generate(a.length, (i) => i).every((i) => same(a[i], b[i]));
      }
      return a == b;
    }

    if (!same(document(), expected)) return false;
    restore({
      'revision': revision,
      ...draft,
      'ranking': [
        for (final e in _scores.entries)
          {
            'entryId': e.key,
            'score': e.value,
            if (_lastUsedDays[e.key] != null)
              'lastUsedAt': _lastUsedDays[e.key],
          },
      ],
    }, _entries.keys.toList());
    return true;
  }

  void restore(Map<String, dynamic> snapshot, Iterable<String> accessible) {
    final next = OrganizationStore()..reconcileEntries(accessible);
    final r = snapshot['revision'],
        tags = snapshot['tags'],
        entries = snapshot['entries'],
        ranking = snapshot['ranking'];
    if (r is! int ||
        r < 0 ||
        tags is! List ||
        tags.length > maxTags ||
        entries is! List ||
        entries.length > maxEntries ||
        ranking is! List ||
        ranking.length > maxEntries) {
      throw ArgumentError('Invalid cloud organization');
    }
    for (final t in tags) {
      if (t is! Map || t['id'] is! String || t['label'] is! String) {
        throw ArgumentError('Invalid cloud tag');
      }
      next.createTag(t['id'] as String, t['label'] as String);
    }
    final seen = <String>{};
    for (final e in entries) {
      if (e is! Map ||
          e['entryId'] is! String ||
          e['pinned'] is! bool ||
          e['tagIds'] is! List ||
          !seen.add(e['entryId'] as String)) {
        throw ArgumentError('Invalid cloud entry');
      }
      final id = e['entryId'] as String;
      final ids = (e['tagIds'] as List).cast<String>();
      if (next._entries.containsKey(id)) {
        next.setPinned(id, e['pinned'] as bool);
        next.setTags(id, ids);
      }
    }
    for (final score in ranking) {
      if (score is! Map ||
          score['entryId'] is! String ||
          score['score'] is! num) {
        throw ArgumentError('Invalid ranking');
      }
      final n = (score['score'] as num).toDouble();
      if (!n.isFinite || n < 0 || n > 90000) {
        throw ArgumentError('Invalid ranking');
      }
      if (next._entries.containsKey(score['entryId'])) {
        next._scores[score['entryId'] as String] = n;
        final day = score['lastUsedAt'];
        if (day is int && day >= 0 && day % 86400000 == 0) {
          next._lastUsedDays[score['entryId'] as String] = day;
        }
      }
    }
    clear();
    _tags.addAll(next._tags);
    _entries.addAll(next._entries);
    _scores.addAll(next._scores);
    _lastUsedDays.addAll(next._lastUsedDays);
    revision = r;
  }

  /// Orders only entries already accessible to the viewer, not code records.
  /// Caller keeps the fresh external/unassigned-code banner ahead of this list.
  /// Pins precede other entries. Frequency ties retain caller catalog order.
  /// No active-code requirement: configured entries remain manageable.
  List<String> orderedEntries(
    Iterable<String> entryIds, {
    required OrganizationOrder order,
    required Iterable<String> selectedTagIds,
    required TagMatch tagMatch,
  }) {
    final ids = entryIds.toList();
    if (ids.length > maxEntries || ids.toSet().length != ids.length) {
      throw ArgumentError('Invalid entry catalog');
    }
    for (final id in ids) {
      _entry(id);
    }
    final selected = selectedTagIds.toSet();
    for (final id in selected) {
      _tag(id);
    }
    final original = <String, int>{
      for (var i = 0; i < ids.length; i++) ids[i]: i,
    };
    final filtered = ids.where((id) {
      final tags = _entries[id]!.tags;
      return selected.isEmpty ||
          (tagMatch == TagMatch.all
              ? selected.every(tags.contains)
              : selected.any(tags.contains));
    }).toList();
    filtered.sort((a, b) {
      final left = _entries[a]!, right = _entries[b]!;
      if (left.pinned != right.pinned) return left.pinned ? -1 : 1;
      if (order == OrganizationOrder.copyFrequency) {
        final frequency = (_scores[b] ?? 0).compareTo(_scores[a] ?? 0);
        if (frequency != 0) return frequency;
      }
      return original[a]!.compareTo(original[b]!);
    });
    return List.unmodifiable(filtered);
  }

  /// Clear before publishing another viewer's catalog.
  void clear() {
    _tags.clear();
    _entries.clear();
    _scores.clear();
    _lastUsedDays.clear();
    revision = 0;
  }

  _Preferences _entry(String id) {
    final entry = _entries[id];
    if (entry == null) throw ArgumentError('Unknown entry');
    return entry;
  }

  void _tag(String id) {
    if (!_tags.containsKey(id)) throw ArgumentError('Unknown tag');
  }

  void _uniqueLabel(String label, {String? except}) {
    if (_tags.values.any(
      (tag) =>
          tag.id != except && tag.label.toLowerCase() == label.toLowerCase(),
    )) {
      throw ArgumentError('Tag label already exists');
    }
  }

  @override
  String toString() => 'OrganizationStore(redacted)';
}

final class _Preferences {
  bool pinned = false;
  Set<String> tags = {};
}

void _identifier(String value) {
  if (value.trim().isEmpty ||
      value.length > 256 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw ArgumentError('Invalid identifier');
  }
}

String _label(String value) {
  final label = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (label.isEmpty ||
      label.runes.length > 80 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(label)) {
    throw ArgumentError('Invalid tag label');
  }
  return label;
}
