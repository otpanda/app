import 'package:material_ui/material_ui.dart';

import 'organization_contract.dart';

/// Display labels for an already-authorized entry, never a code or source.
final class OrganizationPanelEntry {
  final String id, service, account;
  const OrganizationPanelEntry(this.id, this.service, this.account);
  @override
  String toString() => 'OrganizationPanelEntry(redacted)';
}

/// Private organization snapshot. Caller saves changes to its cloud account,
/// reconciles the authorized catalog and invalidates dialogs on new snapshots.
/// Keep fresh code sections ahead of this panel.
class OrganizationPanel extends StatefulWidget {
  final OrganizationStore store;
  final List<OrganizationPanelEntry> entries;
  final VoidCallback? onChanged;
  final int viewerEpoch;
  const OrganizationPanel({
    super.key,
    required this.store,
    required this.entries,
    this.onChanged,
    this.viewerEpoch = 0,
  });
  @override
  State<OrganizationPanel> createState() => _OrganizationPanelState();
}

class _OrganizationPanelState extends State<OrganizationPanel> {
  final Set<String> _selected = {};
  final Map<Route<dynamic>, NavigatorState> _dialogs = {};
  Future<T?> _dialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(context: context, builder: builder);
    _dialogs[route] = navigator;
    try {
      final result = await navigator.push(route);
      await route.completed;
      return result;
    } finally {
      _dialogs.remove(route);
    }
  }

  void _dismissDialogs() {
    final open = Map<Route<dynamic>, NavigatorState>.of(_dialogs);
    _dialogs.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final entry in open.entries) {
        if (entry.value.mounted && entry.key.isActive) {
          entry.value.removeRoute(entry.key);
        }
      }
    });
  }

  @override
  void dispose() {
    _dismissDialogs();
    super.dispose();
  }

  OrganizationOrder _order = OrganizationOrder.copyFrequency;
  TagMatch _match = TagMatch.any;

  @override
  void didUpdateWidget(OrganizationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store) ||
        oldWidget.viewerEpoch != widget.viewerEpoch) {
      _dismissDialogs();
      _selected.clear();
      _order = OrganizationOrder.copyFrequency;
      _match = TagMatch.any;
    }
  }

  void _change(VoidCallback update) {
    setState(update);
    widget.onChanged?.call();
  }

  Future<void> _editTag({PersonalTag? tag}) async {
    final editingStore = widget.store;
    final editingEpoch = widget.viewerEpoch;
    final controller = TextEditingController(text: tag?.label ?? '');
    String? error;
    await _dialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text(tag == null ? 'New personal tag' : 'Rename personal tag'),
          content: SizedBox(
            width: 320,
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: 'Tag name',
                errorText: error,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (!mounted ||
                    (!identical(editingStore, widget.store) ||
                        editingEpoch != widget.viewerEpoch)) {
                  Navigator.pop(context);
                  return;
                }
                try {
                  if (tag == null) {
                    final used = widget.store.tags.map((tag) => tag.id).toSet();
                    var next = 1;
                    while (used.contains('personal-$next')) {
                      next++;
                    }
                    widget.store.createTag('personal-$next', controller.text);
                  } else {
                    widget.store.renameTag(tag.id, controller.text);
                  }
                  _change(() {});
                  Navigator.pop(context);
                } on ArgumentError {
                  refresh(
                    () => error = 'Use a unique name of 1 to 80 characters.',
                  );
                }
              },
              child: const Text('Save tag'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _deleteTag(PersonalTag tag) async {
    final editingStore = widget.store;
    final editingEpoch = widget.viewerEpoch;
    final confirmed = await _dialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete personal tag?'),
        content: Text(
          'Remove "${tag.label}" from all your entries? Entries and services are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete tag'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        (!identical(editingStore, widget.store) ||
            editingEpoch != widget.viewerEpoch)) {
      return;
    }
    _change(() {
      widget.store.deleteTag(tag.id);
      _selected.remove(tag.id);
    });
  }

  Future<void> _assignTags(OrganizationPanelEntry entry) async {
    final editingStore = widget.store;
    final editingEpoch = widget.viewerEpoch;
    final selected = {...widget.store.preferencesFor(entry.id).tagIds};
    final confirmed = await _dialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('Personal tags for entry'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final tag in widget.store.tags)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tag.label),
                      value: selected.contains(tag.id),
                      onChanged: (checked) => refresh(() {
                        checked == true
                            ? selected.add(tag.id)
                            : selected.remove(tag.id);
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply tags'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true &&
        mounted &&
        identical(editingStore, widget.store) &&
        editingEpoch == widget.viewerEpoch) {
      _change(() => widget.store.setTags(entry.id, selected));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = widget.store.tags;
    final tagById = {for (final tag in tags) tag.id: tag};
    final selected = _selected.intersection(tagById.keys.toSet());
    final entries = {for (final entry in widget.entries) entry.id: entry};
    final ordered = widget.store.orderedEntries(
      widget.entries.map((entry) => entry.id),
      order: _order,
      selectedTagIds: selected,
      tagMatch: _match,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Organize your entries',
          style: TextStyle(
            fontFamily: 'BricolageGrotesque',
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Personal tags and pins are separate from service names and account logins. Only your account sees these preferences.',
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () => _editTag(),
              icon: const Icon(Icons.add),
              label: const Text('New tag'),
            ),
          ],
        ),
        if (tags.isEmpty) ...[
          const SizedBox(height: 8),
          const Text('No tags yet. Create a tag, then add it to any entry.'),
        ] else ...[
          const SizedBox(height: 14),
          const Text(
            'Filter by personal tag',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final tag in tags)
                FilterChip(
                  label: SizedBox(
                    width: tag.label.length > 20 ? 150 : null,
                    child: Text(
                      tag.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  selected: selected.contains(tag.id),
                  onSelected: (enabled) => _change(() {
                    enabled ? _selected.add(tag.id) : _selected.remove(tag.id);
                  }),
                ),
            ],
          ),
          if (selected.isNotEmpty)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('Match any'),
                  selected: _match == TagMatch.any,
                  onSelected: (_) => _change(() => _match = TagMatch.any),
                ),
                ChoiceChip(
                  label: const Text('Match all'),
                  selected: _match == TagMatch.all,
                  onSelected: (_) => _change(() => _match = TagMatch.all),
                ),
                TextButton(
                  onPressed: () => _change(_selected.clear),
                  child: const Text('Clear filters'),
                ),
              ],
            ),
          const SizedBox(height: 8),
          for (final tag in tags)
            Row(
              children: [
                Expanded(
                  child: Text(
                    tag.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Rename ${tag.label}',
                  onPressed: () => _editTag(tag: tag),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete ${tag.label}',
                  onPressed: () => _deleteTag(tag),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
        ],
        const SizedBox(height: 16),
        Text(
          '${ordered.length} ${ordered.length == 1 ? 'entry' : 'entries'} · Pinned first',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        if (ordered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.entries.isEmpty ? 'No configured entries yet.' : 'No entries match these tags. Clear filters to see all entries.',
            ),
          ),
        for (final id in ordered) ...[
          Builder(
            builder: (context) {
              final entry = entries[id]!;
              final preferences = widget.store.preferencesFor(id);
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.service,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (entry.account.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    entry.account,
                                    style: const TextStyle(
                                      color: Color(0xff657e70),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: preferences.pinned
                                ? 'Unpin ${entry.service}'
                                : 'Pin ${entry.service}',
                            onPressed: () => _change(
                              () => widget.store.setPinned(
                                id,
                                !preferences.pinned,
                              ),
                            ),
                            icon: Icon(
                              preferences.pinned
                                  ? Icons.push_pin
                                  : Icons.push_pin_outlined,
                            ),
                          ),
                        ],
                      ),
                      if (preferences.tagIds.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final tagId in preferences.tagIds)
                              Chip(
                                label: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 150,
                                  ),
                                  child: Text(
                                    tagById[tagId]!.label,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: tags.isEmpty
                                ? null
                                : () => _assignTags(entry),
                            icon: const Icon(Icons.sell_outlined, size: 18),
                            label: const Text('Edit tags'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}
