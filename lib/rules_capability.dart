import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';

/// Server answer to GET /v1/manage/rules/capabilities. Only this exact shape is
/// believed: {version:1, rules:{available, managementAvailable,
/// disconnectPolicy}}, all strict booleans.
/// - available: create, review, edit and resume readiness.
/// - managementAvailable: reading and deleting existing rules (independent of
///   digest, retention and encryption readiness). False does not mean no rules.
/// - disconnectPolicy: only true allows the signed keep/delete choice on Gmail
///   disconnect.
class RulesCapability {
  const RulesCapability({
    required this.available,
    required this.managementAvailable,
    required this.disconnectPolicy,
  });
  final bool available, managementAvailable, disconnectPolicy;
  bool get showsRules => available || managementAvailable;
}

RulesCapability? parseRulesCapability(String text) {
  try {
    if (text.length > 1024) return null;
    final j = jsonDecode(text);
    if (j is! Map || j.length != 2 || j['version'] != 1) return null;
    final r = j['rules'];
    if (r is! Map ||
        r.length != 3 ||
        r['available'] is! bool ||
        r['managementAvailable'] is! bool ||
        r['disconnectPolicy'] is! bool) {
      return null;
    }
    return RulesCapability(
      available: r['available'] as bool,
      managementAvailable: r['managementAvailable'] as bool,
      disconnectPolicy: r['disconnectPolicy'] as bool,
    );
  } catch (_) {
    return null;
  }
}

/// One fresh probe. Null means unknown (failed, malformed, unexpected shape, or
/// no explicit disconnectPolicy). Never cached here, so an old answer cannot
/// outlive a session, account or config change.
Future<RulesCapability?> probeRulesCapability(RuleBridge bridge) async {
  try {
    return parseRulesCapability(await bridge.rulesCapabilities());
  } catch (_) {
    return null;
  }
}

/// Builds with a capability only after this widget's own probe answered with
/// the exact shape; unknown, failed and pending probes build with null, so no
/// dead control is shown. A late answer for a replaced bridge or a disposed widget is dropped.
class RulesCapable extends StatefulWidget {
  const RulesCapable({super.key, required this.bridge, required this.builder});
  final RuleBridge bridge;
  final Widget Function(BuildContext context, RulesCapability? capability)
  builder;
  @override
  State<RulesCapable> createState() => _RulesCapableState();
}

class _RulesCapableState extends State<RulesCapable> {
  RulesCapability? capability;
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    probe();
  }

  @override
  void didUpdateWidget(RulesCapable old) {
    super.didUpdateWidget(old);
    if (!identical(old.bridge, widget.bridge)) {
      capability = null;
      probe();
    }
  }

  @override
  void dispose() {
    epoch++;
    super.dispose();
  }

  Future<void> probe() async {
    final mine = ++epoch;
    final c = await probeRulesCapability(widget.bridge);
    if (!mounted || mine != epoch) return;
    setState(() => capability = c);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, capability);
}
