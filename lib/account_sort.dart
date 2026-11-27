import 'package:material_ui/material_ui.dart';

enum AccountSort {
  frequentlyUsed('Frequently used'),
  newestFirst('Date added: newest first'),
  oldestFirst('Date added: oldest first'),
  nameAscending('Name: A to Z'),
  nameDescending('Name: Z to A'),
  lastUsed('Last used');

  const AccountSort(this.label);
  final String label;
}

/// Server-provided weighted score is retained, never replaced by a copy count.
/// Missing dates remain unknown. They sort last, with stable catalog ties.
class AccountSortValues {
  const AccountSortValues({
    required this.id,
    required this.name,
    required this.pinned,
    this.score = 0,
    this.createdAt,
    this.lastUsedAt,
  });
  final String id, name;
  final bool pinned;
  final double score;
  final int? createdAt, lastUsedAt;
}

List<String> sortAccounts(
  Iterable<AccountSortValues> accounts,
  AccountSort order,
) {
  final values = accounts.toList();
  final indices = <String, int>{
    for (var i = 0; i < values.length; i++) values[i].id: i,
  };
  if (indices.length != values.length) throw ArgumentError('Duplicate account');
  int date(int? a, int? b, {bool ascending = false}) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return ascending ? a.compareTo(b) : b.compareTo(a);
  }

  values.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final result = switch (order) {
      AccountSort.frequentlyUsed => b.score.compareTo(a.score),
      AccountSort.newestFirst => date(a.createdAt, b.createdAt),
      AccountSort.oldestFirst => date(
        a.createdAt,
        b.createdAt,
        ascending: true,
      ),
      AccountSort.lastUsed => date(a.lastUsedAt, b.lastUsedAt),
      AccountSort.nameAscending => a.name.toLowerCase().compareTo(
        b.name.toLowerCase(),
      ),
      AccountSort.nameDescending => b.name.toLowerCase().compareTo(
        a.name.toLowerCase(),
      ),
    };
    return result != 0 ? result : indices[a.id]!.compareTo(indices[b.id]!);
  });
  return List.unmodifiable(values.map((v) => v.id));
}

/// Icon-only on every platform. The dialog never sorts incoming arrivals.
class AccountSortButton extends StatelessWidget {
  const AccountSortButton({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final AccountSort value;
  final ValueChanged<AccountSort> onChanged;
  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('account-sort-button'),
    icon: const Icon(Icons.sort),
    tooltip: 'Sort accounts: ${value.label}',
    onPressed: () async {
      var current = value;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, refresh) => AlertDialog(
            key: const Key('account-sort-dialog'),
            constraints: const BoxConstraints(maxWidth: 460),
            title: const Text('Sort accounts by'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Applies to your accounts list'),
                  for (final option in AccountSort.values)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        current == option
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      selected: current == option,
                      title: Text(option.label),
                      subtitle: option == AccountSort.frequentlyUsed
                          ? const Text(
                              'Weighted by copy history. Recent copies count more.',
                            )
                          : null,
                      onTap: () {
                        refresh(() => current = option);
                        onChanged(option);
                      },
                    ),
                  const Text(
                    'Pinned accounts stay at the top in every sort order.',
                  ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
