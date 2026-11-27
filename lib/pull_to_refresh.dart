import 'package:material_ui/material_ui.dart';

/// App-provided pull-down refresh for a vertical scroll view.
///
/// The current full-page Flutter web host captures touch scrolling. This
/// fallback keeps the host unchanged. This widget only reports the
/// gesture through [onRefresh]; it chooses no semantics (page reload or data
/// refetch) and never triggers anything by itself. When [enabled] is false the
/// pull settles immediately and calls nothing.
class PullToRefresh extends StatefulWidget {
  const PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.enabled = true,
    this.canStart,
  });

  final Future<void> Function() onRefresh;
  final Widget child;
  final bool enabled;

  /// Checked once at gesture start, never enabled halfway through a drag.
  final bool Function()? canStart;

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();

  /// Touch platforms only. On desktop browsers there is no pull gesture, so
  /// the child is shown as it is and no indicator can appear.
  static bool isMobile(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.android ||
        TargetPlatform.iOS ||
        TargetPlatform.fuchsia => true,
        _ => false,
      };
}

class _PullToRefreshState extends State<PullToRefresh> {
  bool allowed = false;
  @override
  Widget build(BuildContext context) => !PullToRefresh.isMobile(context)
      ? widget.child
      : RefreshIndicator(
          notificationPredicate: (n) {
            if (n.depth != 0) return false;
            if (n is ScrollStartNotification) {
              allowed = widget.enabled && (widget.canStart?.call() ?? true);
            }
            return allowed;
          },
          onRefresh: () async {
            if (allowed && widget.enabled) await widget.onRefresh();
          },
          child: widget.child,
        );
}
