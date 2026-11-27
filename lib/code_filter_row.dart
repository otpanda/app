import 'package:material_ui/material_ui.dart';

/// Input order is deliberate: the caller owns product-specific sorting.
/// This component only moves selected choices first, preserving that order.
class CodeFilterChoice {
  const CodeFilterChoice(this.id, this.label);
  final String id, label;
}

/// One selection set drives both surfaces. No filtering/matching is inferred.
class CodeFilterRow extends StatelessWidget {
  const CodeFilterRow({
    super.key,
    required this.choices,
    required this.selected,
    required this.onChanged,
  });
  final List<CodeFilterChoice> choices;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  List<CodeFilterChoice> get ordered => [
    ...choices.where((c) => selected.contains(c.id)),
    ...choices.where((c) => !selected.contains(c.id)),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final items = ordered;
      // Always reserve a real button-sized area before admitting each chip.
      // More has a fixed width so its counter cannot cause row oscillation.
      const moreWidth = 148.0, gap = 8.0;
      final style =
          Theme.of(context).textTheme.labelLarge ??
          const TextStyle(fontSize: 14);
      var used = 0.0;
      final visible = <CodeFilterChoice>[];
      for (final item in items) {
        final painter = TextPainter(
          text: TextSpan(text: item.label, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        // ChoiceChip: 8px label padding each side, 4px chip padding,
        // selected checkmark up to 24px, plus conservative edge allowance.
        final width = painter.width + 64;
        painter.dispose();
        if (used + width + moreWidth + gap > constraints.maxWidth) break;
        visible.add(item);
        used += width + gap;
      }
      final hidden = items.skip(visible.length).toList();
      return Row(
        children: [
          for (final item in visible)
            Padding(
              padding: const EdgeInsets.only(right: gap),
              child: _chip(item),
            ),
          if (hidden.isNotEmpty)
            SizedBox(
              width: constraints.maxWidth < moreWidth
                  ? constraints.maxWidth
                  : moreWidth,
              child: OutlinedButton(
                key: const Key('code-filter-more'),
                onPressed: () => _more(context),
                child: Text(
                  '${hidden.length} more${hidden.any((c) => selected.contains(c.id)) ? ' · ${hidden.where((c) => selected.contains(c.id)).length} selected' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _chip(CodeFilterChoice c) => FilterChip(
    key: ValueKey('filter-${c.id}'),
    label: Text(c.label),
    selected: selected.contains(c.id),
    onSelected: (enabled) {
      final next = {...selected};
      if (enabled) {
        next.add(c.id);
      } else {
        next.remove(c.id);
      }
      onChanged(Set.unmodifiable(next));
    },
  );

  Future<void> _more(BuildContext context) async {
    // The dialog owns no independent selection. A local view of the same set
    // lets taps update immediately even when the parent row is offstage.
    var current = {...selected};
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('Filters'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in choices)
                    FilterChip(
                      key: ValueKey('dialog-filter-${c.id}'),
                      label: Text(c.label),
                      selected: current.contains(c.id),
                      onSelected: (enabled) {
                        refresh(() {
                          if (enabled) {
                            current.add(c.id);
                          } else {
                            current.remove(c.id);
                          }
                        });
                        onChanged(Set.unmodifiable(current));
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                refresh(() => current.clear());
                onChanged(const {});
              },
              child: const Text('Clear all'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
