import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart';

import 'models.dart';
import 'app_navigation_stub.dart'
    if (dart.library.js_interop) 'app_navigation_web.dart';
import 'branding.dart';
import 'source_preview.dart';
import 'access_preview.dart';
import 'browser_account_page.dart';
import 'browser_session_contract.dart';
import 'fictional_totp_dialog.dart';
import 'native_browser_fallback.dart';
import 'public_service_catalog.dart';

const ink = Color(0xff12281f), green = Color(0xff0a7955);
const line = Color(0xffe0e8e3), pale = Color(0xffe9f8f0);
const muted = Color(0xff5d746a), surface = Color(0xfff4f7f5);

/// Stable, readable avatar colours so each service keeps one look.
Color avatarTint(String name) {
  const tints = [
    Color(0xffdff3e8),
    Color(0xffe3ecfb),
    Color(0xfffbe9dc),
    Color(0xffefe5fa),
    Color(0xfffaf0d2),
    Color(0xffdcf1f3),
  ];
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return tints[h % tints.length];
}

// Web hosts the real account flow. Other platforms have no native sign-in yet
// and show an honest page that opens the web app in the system browser.
void _registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (name, path) in const [
      ('Figtree', 'assets/fonts/Figtree-OFL.txt'),
      ('Bricolage Grotesque', 'assets/fonts/BricolageGrotesque-OFL.txt'),
      ('@zxing/library', 'assets/zxing/zxing-library-LICENSE.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString(path));
    }
  });
}

void main() {
  _registerFontLicenses();
  runApp(kIsWeb ? const OTPandaApp() : const NativeBrowserFallbackApp());
}

ThemeData otpandaTheme() => ThemeData(
  fontFamily: 'Figtree',
  appBarTheme: const AppBarTheme(
    centerTitle: false,
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    titleTextStyle: TextStyle(
      fontFamily: 'BricolageGrotesque',
      fontSize: 20,
      fontWeight: FontWeight.w800,
      color: ink,
    ),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: Colors.white,
    indicatorColor: pale,
    surfaceTintColor: Colors.transparent,
    labelTextStyle: WidgetStateProperty.all(
      const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
    ),
  ),
  dialogTheme: DialogThemeData(
    titleTextStyle: const TextStyle(
      fontFamily: 'BricolageGrotesque',
      fontSize: 22,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      side: const BorderSide(color: line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
  useMaterial3: true,
  scaffoldBackgroundColor: surface,
  colorScheme: ColorScheme.fromSeed(seedColor: green),
  textTheme: const TextTheme(bodyMedium: TextStyle(color: ink, fontSize: 13)),
  cardTheme: const CardThemeData(
    elevation: 0,
    color: Colors.white,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
      side: BorderSide(color: line),
    ),
  ),
);

class OTPandaApp extends StatelessWidget {
  const OTPandaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OTPanda',
    debugShowCheckedModeBanner: false,
    theme: otpandaTheme(),
    // The host owns browser history. Flutter must not overwrite #/ URLs.
    builder: (context, child) => Navigator(
      reportsRouteUpdateToEngine: false,
      onGenerateRoute: (_) =>
          MaterialPageRoute<void>(builder: (_) => const AccountEntryRouter()),
    ),
  );
}

/// Resume only the bounded account flow after a first-party API callback.
/// The fictional workspace remains separate from authenticated account data.
class AccountEntryRouter extends StatefulWidget {
  final BrowserSessionBridge? bridge;
  const AccountEntryRouter({super.key, this.bridge});
  @override
  State<AccountEntryRouter> createState() => _AccountEntryRouterState();
}

class _AccountEntryRouterState extends State<AccountEntryRouter>
    with WidgetsBindingObserver {
  late final AppNavigation navigation;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    navigation = AppNavigation();
    navigation.onChange = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    navigation.dispose();
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) => navigation.current == 'demo'
      ? ClientHome(fictionalCatalog: true, onExit: () => navigation.go('codes'))
      : BrowserAccountPage(
          bridge: widget.bridge,
          navigation: navigation.current,
          onNavigate: navigation.go,
          loginEnabled: true,
          accountOnly: true,
          workspaceEnabled: true,
        );
}

class ClientHome extends StatefulWidget {
  // Opt-in only for the local fixture catalog, never inferred from permissions.
  final bool fictionalCatalog;
  final int initialTab;
  // Test/preview fixture: start with no entries or codes, never for real data.
  final bool emptyFixture;
  final VoidCallback? onExit;
  const ClientHome({
    super.key,
    this.fictionalCatalog = false,
    this.initialTab = 0,
    this.emptyFixture = false,
    this.onExit,
  });
  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome> {
  late int tab = widget.initialTab;
  String query = '';
  int entrySequence = 0;
  bool sourceRevoked = false;
  bool tokenRevoked = false;
  late final entries = widget.emptyFixture
      ? <AccountEntry>[]
      : [
          const AccountEntry('north', 'Northstar', 'alex@example.test', true),
          const AccountEntry('harbor', 'Harbor', 'team@example.test', false),
          const AccountEntry('orchard', 'Orchard', 'alex-work', true),
        ];
  late final codes = <String, String>{
    if (!widget.emptyFixture) 'north': '123456',
  };
  late bool unassigned = !widget.emptyFixture;
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
    String? retainedId = entry?.serviceId, retainedHost = entry?.websiteHost;
    String retainedLabel = entry?.service ?? '';
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
                if (entry == null)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.search),
                    label: const Text('Find a service'),
                    onPressed: () async {
                      final selected = await showDialog<PublicService>(
                        context: context,
                        builder: (_) => const PublicServicePicker(),
                      );
                      if (selected != null && context.mounted) {
                        service.text = selected.name;
                        retainedLabel = selected.name;
                        retainedId = selected.id;
                        retainedHost = selected.host;
                      }
                    },
                  ),
                TextFormField(
                  controller: service,
                  onChanged: (value) {
                    if (value != retainedLabel) {
                      retainedId = null;
                      retainedHost = null;
                    }
                  },
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
                    serviceId: retainedId,
                    websiteHost: retainedHost,
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
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Future<void> previewGeneratedCode(AccountEntry entry) async {
    if (!widget.fictionalCatalog) return;
    await showDialog<void>(
      context: context,
      builder: (_) => FictionalTotpDialog(
        entryId: entry.id,
        service: entry.service,
        account: entry.account,
      ),
    );
  }

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
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: avatarTint(e.service),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              e.service.isEmpty ? '?' : e.service[0].toUpperCase(),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: ink,
              ),
            ),
          ),
          const SizedBox(width: 11),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.service,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                e.account,
                style: const TextStyle(fontSize: 12, color: muted),
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
          style: TextStyle(
            fontFamily: 'Figtree',
            fontFeatures: const [FontFeature.tabularFigures()],
            fontSize: compact ? 22 : 26,
            fontWeight: FontWeight.w600,
            color: ink,
            letterSpacing: compact ? 0.5 : 1.5,
          ),
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          tooltip: 'Copy fictional code',
          onPressed: code == null ? null : () => copy(code),
          icon: const Icon(Icons.copy_outlined, size: 18),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
      ],
    );
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                ),
            ],
            Text(
              e.manage
                  ? (code == null ? 'Source not connected' : 'Latest code')
                  : 'Shared · Read-only · Source hidden',
              style: const TextStyle(fontSize: 11, color: muted),
            ),
            if (widget.fictionalCatalog)
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                  foregroundColor: muted,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () => previewGeneratedCode(e),
                child: const Text('Preview fictional generated code'),
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
    Widget? extra,
  }) {
    final columns = width >= 850
        ? 3
        : width >= 520
        ? 2
        : 1;
    final itemWidth = (width - (columns - 1) * 11) / columns;
    return Wrap(
      spacing: 11,
      runSpacing: 11,
      children:
          list
              .map<Widget>(
                (e) => SizedBox(width: itemWidth, child: card(e, compact)),
              )
              .toList()
            ..addAll([
              if (extra != null) SizedBox(width: itemWidth, child: extra),
            ]),
    );
  }

  Widget unassignedCard({bool spaced = true}) => Container(
    margin: EdgeInsets.only(top: spaced ? 12 : 0),
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
                fontFamily: 'Figtree',
                fontFeatures: [FontFeature.tabularFigures()],
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
          if (!desktop)
            const Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                key: ValueKey('sample-chip'),
                label: Text('Temporary demo data'),
                visualDensity: VisualDensity.compact,
                backgroundColor: Color(0xfffff3d6),
                side: BorderSide.none,
                labelStyle: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff7a5a12),
                ),
              ),
            ),
          Text(
            tab == 0 ? 'Your codes' : names[tab],
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontFamily: 'BricolageGrotesque',
              fontSize: 28,
              letterSpacing: -0.8,
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
            style: const TextStyle(color: muted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          if (tab == 0 || tab == 4) ...[
            TextField(
              key: ValueKey(tab),
              decoration: const InputDecoration(
                hintText: 'Search services or accounts',
                prefixIcon: Icon(Icons.search, size: 20),
                contentPadding: EdgeInsets.symmetric(vertical: 14),
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  borderSide: BorderSide(color: line),
                ),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
            const SizedBox(height: 15),
          ],
          if (tab == 0) ...[
            if (received.isEmpty && !unassigned && rest.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        query.isEmpty ? 'No codes yet' : 'No matches',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        query.isEmpty
                            ? 'Add a source and your codes show up here the moment they arrive.'
                            : 'Nothing matches your search.',
                      ),
                      if (query.isEmpty) ...[
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton(
                              onPressed: () => navigate(1),
                              child: const Text('Add a source'),
                            ),
                            OutlinedButton(
                              onPressed: () => navigate(4),
                              child: const Text('Add an entry'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (received.isNotEmpty || unassigned)
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: pale,
                  border: Border.all(color: const Color(0xffb7e6cd)),
                  borderRadius: BorderRadius.circular(18),
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
                        extra: unassigned
                            ? unassignedCard(spaced: false)
                            : null,
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
            'Temporary demo data. Changes here are not saved and reset when you restart.',
            style: TextStyle(fontSize: 12, color: muted),
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
                        fontFamily: 'BricolageGrotesque',
                        fontSize: 23,
                        letterSpacing: -1,
                        color: ink,
                      ),
                    ),
                    const Spacer(),
                    if (desktop) ...[
                      Container(
                        key: const ValueKey('sample-chip'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xfffff3d6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Temporary demo data',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xff7a5a12),
                          ),
                        ),
                      ),
                    ],
                    if (desktop) const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Account & security',
                      onPressed:
                          widget.onExit ??
                          () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) => const BrowserAccountPage(
                                loginEnabled: true,
                                accountOnly: true,
                              ),
                            ),
                          ),
                      icon: const Icon(Icons.account_circle_outlined, size: 26),
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
                                  width: 232,
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
                                            dense: false,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(9),
                                            ),
                                            selected: tab == i,
                                            selectedTileColor: pale,
                                            selectedColor: green,
                                            leading: Icon(icons[i], size: 18),
                                            title: Text(
                                              names[i],
                                              style: const TextStyle(
                                                fontSize: 14,
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
                height: 72,
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
