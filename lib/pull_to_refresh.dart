import 'package:material_ui/material_ui.dart';

/// App-provided pull-down refresh for a vertical scroll view.
///
/// The current full-page Flutter web host captures touch scrolling. This
/// fallback keeps the host unchanged. This widget only reports the
/// gesture through [onRefresh]; it chooses no semantics (page reload or data
/// refetch) and never triggers anything by itself. When [enabled] is false the
/// pull settles immediately and calls nothing.
class PullToRefresh extends StatelessWidget {
  const PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.enabled = true,
  });

  final Future<void> Function() onRefresh;
  final Widget child;
  final bool enabled;

  /// Touch platforms only. On desktop browsers there is no pull gesture, so
  /// the child is shown as it is and no indicator can appear.
  static bool isMobile(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.android ||
        TargetPlatform.iOS ||
        TargetPlatform.fuchsia => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) => !isMobile(context)
      ? child
      : RefreshIndicator(
          onRefresh: () async {
            if (enabled) await onRefresh();
          },
          child: child,
        );
}
