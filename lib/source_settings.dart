import 'package:material_ui/material_ui.dart';

import 'gmail_source.dart';
import 'read_workspace_controller.dart';
import 'settings_hub.dart';

class SourceSettings extends StatelessWidget {
  const SourceSettings({
    super.key,
    required this.controller,
    this.onOpenAccount,
  });
  final ReadWorkspaceController controller;
  final VoidCallback? onOpenAccount;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final bridge = controller.bridge;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (bridge is GmailSourceBridge)
            GmailSourceConnect(
              bridge: bridge as GmailSourceBridge,
              onOpenAccount: onOpenAccount,
              hasGmailSource: controller.store.sources.any(
                (s) => s.kind == 'gmail',
              ),
            ),
          if (controller.store.sources.isEmpty)
            settingsCard('Sources', const [
              Text('No sources connected. Connect a mailbox to receive codes.'),
            ]),
          for (final source in controller.store.sources)
            settingsCard(source.label, [
              Text(source.kind.toUpperCase()),
              if (source.kind == 'gmail' && bridge is GmailSourceBridge)
                GmailSourceDisconnect(
                  bridge: bridge as GmailSourceBridge,
                  sourceId: source.id,
                  label: source.label,
                  onChanged: () => controller.refresh(),
                ),
            ]),
        ],
      );
    },
  );
}
