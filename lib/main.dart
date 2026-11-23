import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'models.dart';

void main() => runApp(const OTPandaApp());

class OTPandaApp extends StatelessWidget {
  const OTPandaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OTPanda',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff0a7955)),
      useMaterial3: true,
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
  final entries = [
    const AccountEntry('north', 'Northstar', 'alex@example.test', true),
    const AccountEntry('harbor', 'Harbor', 'team@example.test', false),
    const AccountEntry('orchard', 'Orchard', 'alex-work', true),
  ];
  final codes = <String, String>{'north': '123456'};
  bool unassigned = true;
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
                  onChanged: (value) => setDialog(() => selected = value),
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

  Widget card(AccountEntry entry) {
    final code = codes[entry.id];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.service, style: Theme.of(context).textTheme.titleMedium),
            Text(entry.account),
            if (code != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      code,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy fictional code',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: code));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Fictional code copied. Other apps may retain clipboard contents.',
                            ),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy),
                  ),
                ],
              )
            else
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No active code'),
              ),
            if (!entry.manage)
              const Text('Shared, read-only', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final names = ['Codes', 'Sources', 'Access', 'Entries'];
    return Scaffold(
      appBar: AppBar(title: const Text('OTPanda')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Card(
                  color: Color(0xffe7f8ee),
                  child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      'Flutter development preview. Fictional data only. No sign-in, real sources or account changes. Resets when restarted.',
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  names[tab],
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                if (tab == 0 || tab == 3) ...[
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search service or username',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => query = v),
                  ),
                  const SizedBox(height: 14),
                  if (tab == 0 && unassigned)
                    Card(
                      color: const Color(0xffe7f8ee),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Unassigned · Only you'),
                            Text(
                              '654321',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            TextButton(
                              onPressed: chooseAccount,
                              child: const Text('Choose account'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ...entries.where((e) => e.matches(query)).map(card),
                ] else
                  Text(
                    tab == 1
                        ? 'Source setup is not connected in this Flutter preview. SMS collection will be a separate opt-in.'
                        : 'Automation token management is not connected in this Flutter preview. Use the existing web preview to inspect that flow.',
                  ),
                const SizedBox(height: 20),
                const Text(
                  'This is not a working cloud account. Platform login, secure storage, source setup and management parity are still being implemented.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() {
          tab = i;
          query = '';
        }),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.password), label: 'Codes'),
          NavigationDestination(icon: Icon(Icons.devices), label: 'Sources'),
          NavigationDestination(icon: Icon(Icons.key), label: 'Access'),
          NavigationDestination(icon: Icon(Icons.list), label: 'Entries'),
        ],
      ),
    );
  }
}
