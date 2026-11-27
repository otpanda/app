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
      const gap = 8.0;
      final style =
          Theme.of(context).textTheme.labelLarge ??
          const TextStyle(fontSize: 14);
      double textWidth(String label) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      String moreLabel(List<CodeFilterChoice> hidden) {
        final count = hidden.where((c) => selected.contains(c.id)).length;
        return '${hidden.length} more${count > 0 ? ' · $count selected' : ''}';
      }

      // Explicit chip padding makes measurement match the rendered chips.
      final widths = [
        for (final item in items)
          textWidth(item.label) + 24 + (selected.contains(item.id) ? 24 : 0),
      ];
      double occupied(int count) =>
          widths.take(count).fold(0.0, (a, b) => a + b) +
          (count > 0 ? (count - 1) * gap : 0);
      var count = items.length;
      var moreWidth = 0.0;
      if (occupied(count) > constraints.maxWidth) {
        // Try the whole row first. Reserve a compact overflow control only
        // when at least one chip genuinely does not fit.
        for (count = items.length - 1; count >= 0; count--) {
          moreWidth = (textWidth(moreLabel(items.skip(count).toList())) + 32)
              .clamp(0.0, constraints.maxWidth);
          if (occupied(count) + (count > 0 ? gap : 0) + moreWidth <=
              constraints.maxWidth) {
            break;
          }
        }
      }
      final visible = items.take(count < 0 ? 0 : count).toList();
      final hidden = items.skip(visible.length).toList();
      return Row(
        children: [
          for (final item in visible)
            Padding(
              padding: EdgeInsets.only(
                right: item != visible.last || hidden.isNotEmpty ? gap : 0,
              ),
              child: _chip(item),
            ),
          if (hidden.isNotEmpty)
            SizedBox(
              width: constraints.maxWidth < moreWidth
                  ? constraints.maxWidth
                  : moreWidth,
              child: OutlinedButton(
                key: const Key('code-filter-more'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  textStyle: style,
                ),
                onPressed: () => _more(context),
                child: Text(
                  moreLabel(hidden),
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
    padding: const EdgeInsets.all(4),
    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
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
    final frozenOrder = ordered;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          constraints: const BoxConstraints(maxWidth: 520),
          title: const Text('Filters'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in frozenOrder)
                        FilterChip(
                          key: ValueKey('dialog-filter-${c.id}'),
                          label: Text(c.label),
                          padding: const EdgeInsets.all(4),
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
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
