import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class PublicService {
  final String id, name, host;
  const PublicService(this.id, this.name, this.host);
}

class PublicServiceCatalog {
  final List<PublicService> services;
  final int fetchedAt;
  const PublicServiceCatalog(this.services, this.fetchedAt);
  static PublicServiceCatalog? _bundled;
  static Future<PublicServiceCatalog> bundled() async {
    if (_bundled != null) return _bundled!;
    final text = await rootBundle.loadString('assets/service-catalog.json');
    return _bundled = PublicServiceCatalog.parse(text);
  }

  factory PublicServiceCatalog.parse(String text) {
    if (utf8.encode(text).length > 1024 * 1024) {
      throw const FormatException('Catalog too large');
    }
    final data = jsonDecode(text);
    if (data is! Map<String, dynamic> ||
        data['source'] != 'https://api.2fa.directory/v3/all.json' ||
        data['license'] != 'MIT' ||
        data['attribution'] !=
            'Data sourced from 2FA Directory by 2factorauth.' ||
        data['signatureVerified'] != false ||
        data['fetchedAt'] is! int ||
        data['fetchedAt'] < 0 ||
        data['fetchedAt'] > 8640000000000000 ||
        data['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['sha256']) ||
        data['services'] is! List) {
      throw const FormatException('Invalid public catalog');
    }
    final rows = data['services'] as List;
    if (rows.isEmpty || rows.length > 5000) {
      throw const FormatException('Catalog row limit');
    }
    final ids = <String>{};
    final services = <PublicService>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic> ||
          row.keys.toSet().difference({'id', 'name', 'host'}).isNotEmpty ||
          row['id'] is! String ||
          row['id'] != row['host'] ||
          row['id'].length > 128 ||
          !RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$').hasMatch(row['id']) ||
          RegExp(r'^[0-9.]+$').hasMatch(row['id']) ||
          [
            '.local',
            '.localhost',
            '.internal',
          ].any((suffix) => (row['id'] as String).endsWith(suffix)) ||
          (row['id'] as String)
              .split('.')
              .any(
                (part) =>
                    part.length > 63 ||
                    part.startsWith('-') ||
                    part.endsWith('-'),
              ) ||
          !ids.add(row['id']) ||
          row['name'] is! String ||
          row['name'].trim().isEmpty ||
          row['name'].length > 120 ||
          RegExp(
            r'[\u{0}-\u{1f}\u{7f}-\u{9f}\u{ad}\u{600}-\u{605}\u{61c}\u{6dd}\u{70f}\u{890}-\u{891}\u{8e2}\u{180e}\u{200b}-\u{200f}\u{2028}-\u{202e}\u{2060}-\u{206f}\u{feff}\u{fff9}-\u{fffb}\u{110bd}\u{110cd}\u{13430}-\u{1345f}\u{1bca0}-\u{1bca3}\u{1d173}-\u{1d17a}\u{e0001}\u{e0020}-\u{e007f}]',
            unicode: true,
          ).hasMatch(row['name'])) {
        throw const FormatException('Invalid public service');
      }
      services.add(PublicService(row['id'], row['name'], row['host']));
    }
    return PublicServiceCatalog(List.unmodifiable(services), data['fetchedAt']);
  }

  List<PublicService> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return services
        .where((s) => s.name.toLowerCase().contains(q) || s.host.contains(q))
        .take(20)
        .toList(growable: false);
  }
}

class PublicServicePicker extends StatefulWidget {
  const PublicServicePicker({super.key});
  @override
  State<PublicServicePicker> createState() => _PublicServicePickerState();
}

class _PublicServicePickerState extends State<PublicServicePicker> {
  final catalog = PublicServiceCatalog.bundled();
  String query = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('Find a service')),
        IconButton(
          tooltip: 'Close service picker',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    content: SizedBox(
      width: 440,
      height: 340,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Public names only. Selecting a service does not connect it or recognize its OTP senders.',
          ),
          const SizedBox(height: 12),
          TextField(
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Service name or website',
            ),
            onChanged: (value) => setState(() => query = value),
          ),
          Expanded(
            child: FutureBuilder<PublicServiceCatalog>(
              future: catalog,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text(
                    'Catalog unavailable. Close this picker and enter a custom label.',
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final results = snapshot.data!.search(query);
                return ListView(
                  children: [
                    if (query.trim().isEmpty)
                      const Text(
                        'Type to search. You can always use a custom label instead.',
                      ),
                    if (query.trim().isNotEmpty && results.isEmpty)
                      const Text(
                        'No matching service. Close this picker to use a custom label.',
                      ),
                    for (final service in results)
                      ListTile(
                        title: Text(service.name),
                        subtitle: Text(service.host),
                        onTap: () => Navigator.pop(context, service),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Snapshot checked ${DateTime.fromMillisecondsSinceEpoch(snapshot.data!.fetchedAt, isUtc: true).toIso8601String().substring(0, 10)} UTC. Not proof of current service support.',
                    ),
                    const Text(
                      'Data sourced from 2FA Directory by 2factorauth. MIT license. https://2fa.directory',
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
