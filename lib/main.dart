import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'branding.dart';
import 'source_preview.dart';
import 'access_preview.dart';
import 'account_preview.dart';

const ink = Color(0xff17332a), green = Color(0xff0a7955);
const line = Color(0xffdfe8e2), pale = Color(0xffe7f8ee);
void main() => runApp(const OTPandaApp());

class OTPandaApp extends StatelessWidget {
  const OTPandaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OTPanda',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 10)),
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff5f8f7),
      colorScheme: ColorScheme.fromSeed(seedColor: green),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: ink, fontSize: 13),
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        color: Colors.white,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(11)),
          side: BorderSide(color: line),
        ),
      ),
    ),
    home: const ClientHome(),
  );
}

class ClientHome extends StatefulWidget {
  const ClientHome({super.key});
  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome> {
  int tab = 0;
  String query = '';
  int entrySequence = 0;
  bool sourceRevoked = false;
  bool tokenRevoked = false;
  final entries = [
    const AccountEntry('north', 'Northstar', 'alex@example.test', true),
    const AccountEntry('harbor', 'Harbor', 'team@example.test', false),
    const AccountEntry('orchard', 'Orchard', 'alex-work', true),
  ];
  final codes = <String, String>{'north': '123456'};
  bool unassigned = true;
  static const names = ['Codes', 'Sources', 'Access', 'Unassigned', 'Entries'];
  static const icons = [
    Icons.password,
    Icons.inbox_outlined,
    Icons.shield_outlined,
    Icons.crop_free,
    Icons.list,
  ];
  void navigate(int value) => setState(() {
    tab = value;
    query = '';
  });
  Future<void> chooseAccount() async {
    String? selected;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('Assign this code')),
              IconButton(
                tooltip: 'Close dialog',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Choose an owned entry. Shared recipients could read this code. This assigns only this code, not future messages.',
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Owned entry'),
                  initialValue: null,
                  items: entries
                      .where((e) => e.manage)
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.id,
                          child: Text(
                            e.service,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setDialog(() => selected = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(context, selected),
              child: const Text('Assign code'),
            ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) {
      setState(() {
        codes[choice] = '654321';
        unassigned = false;
      });
    }
  }

  Widget dialogTitle(BuildContext context, String title) => Row(
    children: [
      Expanded(child: Text(title)),
      IconButton(
        tooltip: 'Close dialog',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close),
      ),
    ],
  );

  Future<void> editEntry([AccountEntry? entry]) async {
    if (entry != null && !entry.manage) return;
    final service = TextEditingController(text: entry?.service ?? '');
    final account = TextEditingController(text: entry?.account ?? '');
    final form = GlobalKey<FormState>();
    final result = await showDialog<AccountEntry>(
      context: context,
      builder: (context) => AlertDialog(
        title: dialogTitle(context, entry == null ? 'Add entry' : 'Edit entry'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Fictional preview only. This does not create a real account, connect a source or add an authenticator key.',
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: service,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: 'Service or entry label',
                  ),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter a service or label.'
                      : null,
                ),
                TextFormField(
                  controller: account,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: 'Username or login (optional)',
                  ),
                ),
              ],
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
              if (form.currentState!.validate()) {
                Navigator.pop(
                  context,
                  AccountEntry(
                    entry?.id ?? 'demo-${++entrySequence}',
                    service.text.trim(),
                    account.text.trim(),
                    true,
                  ),
                );
              }
            },
            child: Text(entry == null ? 'Create entry' : 'Save changes'),
          ),
        ],
      ),
    );
    // Dispose after the dialog's closing animation releases its text fields.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    service.dispose();
    account.dispose();
    if (result != null && mounted) {
      setState(() {
        final index = entries.indexWhere((e) => e.id == result.id);
        if (index < 0) {
          entries.add(result);
        } else {
          entries[index] = result;
        }
      });
    }
  }

  Future<void> deleteEntry(AccountEntry entry) async {
    if (!entry.manage) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: dialogTitle(context, 'Delete entry?'),
        content: Text(
          'Delete ${entry.service} and its fictional saved code? This cannot be undone except by restarting this demo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete entry'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        entries.removeWhere((e) => e.id == entry.id);
        codes.remove(entry.id);
      });
    }
  }

  Widget entryManagement(List<AccountEntry> visible) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: () => editEntry(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add entry'),
        ),
      ),
      const SizedBox(height: 12),
      if (visible.isEmpty)
        const Padding(
          padding: EdgeInsets.all(18),
          child: Text('No matching entries.'),
        ),
      ...visible.map(
        (entry) => Padding(
          padding: const EdgeInsets.only(bottom: 11),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  identity(entry),
                  const SizedBox(height: 10),
                  if (entry.manage)
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => editEntry(entry),
                          child: const Text('Edit entry'),
                        ),
                        TextButton(
                          onPressed: () => deleteEntry(entry),
                          child: const Text('Delete entry'),
                        ),
                      ],
                    )
                  else
                    const Text(
                      'Shared, read-only. Only the owner can change this entry.',
                      style: TextStyle(fontSize: 11, color: Color(0xff657e70)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Future<void> copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Fictional code copied. Other apps may retain clipboard contents.',
          ),
        ),
      );
    }
  }

  Widget identity(AccountEntry e) => LayoutBuilder(
    builder: (context, bounds) => Row(
      children: [
        if (bounds.maxWidth >= 80) ...[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xffedf5f0),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              e.service[0],
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          const SizedBox(width: 9),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.service,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                e.account,
                style: const TextStyle(fontSize: 11, color: Color(0xff657e70)),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget card(AccountEntry e, bool compact) {
    final code = codes[e.id];
    final digits = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          code == null ? '' : '${code.substring(0, 3)} ${code.substring(3)}',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 23,
            color: ink,
            letterSpacing: 1,
          ),
        ),
        IconButton(
          tooltip: 'Copy fictional code',
          onPressed: code == null ? null : () => copy(code),
          icon: const Icon(Icons.copy_outlined, size: 18),
          constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
        ),
      ],
    );
    return Card(
      color: code == null ? Colors.white : const Color(0xfff5fff8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (compact && code != null)
              Row(
                children: [
                  Expanded(child: identity(e)),
                  const SizedBox(width: 5),
                  digits,
                ],
              )
            else ...[
              identity(e),
              if (code != null)
                Align(alignment: Alignment.centerLeft, child: digits)
              else
                const Padding(
                  padding: EdgeInsets.only(top: 12, bottom: 8),
                  child: Text(
                    'No active code',
                    style: TextStyle(color: Color(0xff657e70), fontSize: 12),
                  ),
                ),
            ],
            Text(
              e.manage
                  ? (code == null
                        ? 'Source not connected'
                        : 'Fictional received code')
                  : 'Shared · Read-only · Source hidden',
              style: const TextStyle(fontSize: 10, color: Color(0xff657e70)),
            ),
          ],
        ),
      ),
    );
  }

  Widget grid(
    List<AccountEntry> list,
    double width,
    bool compact, {
    bool received = false,
  }) {
    final columns = received && width >= 520
        ? 2
        : width >= 850
        ? 3
        : width >= 520
        ? 2
        : 1;
    final itemWidth = (width - (columns - 1) * 11) / columns;
    return Wrap(
      spacing: 11,
      runSpacing: 11,
      children: list
          .map((e) => SizedBox(width: itemWidth, child: card(e, compact)))
          .toList(),
    );
  }

  Widget unassignedCard() => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xfff2fcf6),
      border: Border.all(color: const Color(0xffc5e7d4)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Needs an account match · Only you',
          style: TextStyle(fontSize: 11, color: Color(0xff547462)),
        ),
        const SizedBox(height: 9),
        const Row(
          children: [
            Expanded(
              child: Text(
                'Unassigned code',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              '654 321',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 23,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        TextButton(
          onPressed: chooseAccount,
          child: const Text('Choose account'),
        ),
      ],
    ),
  );
  Widget content(bool desktop) => LayoutBuilder(
    builder: (context, size) {
      final visible = entries.where((e) => e.matches(query)).toList();
      final received = visible.where((e) => codes.containsKey(e.id)).toList();
      final rest = visible.where((e) => !codes.containsKey(e.id)).toList();
      final width = size.maxWidth;
      return ListView(
        padding: EdgeInsets.fromLTRB(
          desktop ? 0 : 12,
          20,
          desktop ? 0 : 12,
          30,
        ),
        children: [
          Text(
            tab == 0 ? 'Your codes' : names[tab],
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 26,
              letterSpacing: -1,
              color: ink,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            [
              'Find the code you came for.',
              'Your private connected sources.',
              'Access to your selected entries.',
              'Private incoming codes awaiting assignment.',
              'All your configured entries.',
            ][tab],
            style: const TextStyle(color: Color(0xff657e70), fontSize: 12),
          ),
          const SizedBox(height: 18),
          if (tab == 0 || tab == 4) ...[
            TextField(
              key: ValueKey(tab),
              decoration: const InputDecoration(
                hintText: 'Search services or accounts',
                prefixIcon: Icon(Icons.search, size: 19),
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(9)),
                  borderSide: BorderSide(color: line),
                ),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
            const SizedBox(height: 15),
          ],
          if (tab == 0) ...[
            if (received.isNotEmpty || unassigned)
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: pale,
                  border: Border.all(color: const Color(0xffafe4c9)),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.inbox_outlined, size: 17, color: green),
                        SizedBox(width: 7),
                        Text(
                          'Received codes',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, inner) => grid(
                        received,
                        inner.maxWidth,
                        !desktop,
                        received: true,
                      ),
                    ),
                    if (unassigned)
                      LayoutBuilder(
                        builder: (context, inner) => SizedBox(
                          width: inner.maxWidth >= 520
                              ? (inner.maxWidth - 11) / 2
                              : inner.maxWidth,
                          child: unassignedCard(),
                        ),
                      ),
                  ],
                ),
              ),
            if (rest.isNotEmpty) ...[
              const SizedBox(height: 22),
              const Text(
                'Your entries',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              grid(rest, width - (desktop ? 0 : 24), !desktop),
            ],
          ] else if (tab == 4)
            entryManagement(visible)
          else if (tab == 3)
            unassigned ? unassignedCard() : const Text('No unassigned codes.')
          else if (tab == 1)
            SourcePreview(
              revoked: sourceRevoked,
              onRevoke: () => setState(() => sourceRevoked = true),
            )
          else
            AccessPreview(
              tokenRevoked: tokenRevoked,
              onRevoke: () => setState(() => tokenRevoked = true),
            ),
          const SizedBox(height: 24),
          const Text(
            'Fictional data only. No sign-in, real sources or account changes. Resets when restarted. Platform login, secure storage and management parity are still being implemented.',
            style: TextStyle(fontSize: 11, color: Color(0xff657e70)),
          ),
        ],
      );
    },
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final desktop = size.maxWidth > 700;
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 7,
                  horizontal: 12,
                ),
                color: const Color(0xfffff6df),
                child: const Text(
                  'DEVELOPMENT PREVIEW · Fictional accounts and codes · Nothing connected',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: Color(0xff7a6029)),
                ),
              ),
              Container(
                height: desktop ? 76 : 64,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: line)),
                ),
                padding: EdgeInsets.symmetric(horizontal: desktop ? 32 : 16),
                child: Row(
                  children: [
                    Image.memory(
                      ottyImage,
                      width: desktop ? 48 : 42,
                      height: desktop ? 48 : 42,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'OTPanda',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 23,
                        letterSpacing: -1,
                        color: ink,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Account & security',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (context) => const AccountSecurityPreview(),
                        ),
                      ),
                      icon: const Icon(Icons.person_outline),
                    ),
                    if (desktop)
                      const Text(
                        'YOUR PRIVATE CODE SPACE',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.4,
                          color: Color(0xff657e70),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1260),
                    child: desktop
                        ? Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 210,
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      top: 22,
                                      right: 18,
                                    ),
                                    child: Column(
                                      children: List.generate(
                                        names.length,
                                        (i) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: ListTile(
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                ),
                                            minLeadingWidth: 18,
                                            horizontalTitleGap: 10,
                                            dense: true,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(9),
                                            ),
                                            selected: tab == i,
                                            selectedTileColor: green,
                                            selectedColor: Colors.white,
                                            leading: Icon(icons[i], size: 18),
                                            title: Text(
                                              names[i],
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            onTap: () => navigate(i),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(child: content(true)),
                              ],
                            ),
                          )
                        : content(false),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: desktop
            ? null
            : NavigationBar(
                height: 68,
                selectedIndex: tab,
                onDestinationSelected: navigate,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: List.generate(
                  names.length,
                  (i) => NavigationDestination(
                    icon: Icon(icons[i], size: 20),
                    label: names[i],
                  ),
                ),
              ),
      );
    },
  );
}
