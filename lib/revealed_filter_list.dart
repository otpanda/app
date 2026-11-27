import 'package:material_ui/material_ui.dart';

/// Observes real list scrolls without consuming a gesture or overscroll.
/// Place below the fixed app bar and around the existing refresh wrapper.
/// Desktop is always visible; mobile starts with no row space reserved.
class RevealedFilterList extends StatefulWidget {
  const RevealedFilterList({
    super.key,
    required this.mobile,
    required this.filters,
    required this.child,
  });
  final bool mobile;
  final Widget filters, child;
  @override
  State<RevealedFilterList> createState() => _RevealedFilterListState();
}

class _RevealedFilterListState extends State<RevealedFilterList> {
  bool shown = false;
  double travel = 0;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (!widget.mobile || shown) widget.filters,
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (!widget.mobile ||
                n.depth != 0 ||
                n.metrics.axis != Axis.vertical) {
              return false;
            }
            if (n is ScrollStartNotification) travel = 0;
            if (n is ScrollUpdateNotification && n.dragDetails != null) {
              final delta = n.scrollDelta ?? 0;
              if (delta != 0) {
                if (travel.sign != delta.sign) travel = 0;
                travel += delta;
                if (!shown && travel <= -16) {
                  setState(() => shown = true);
                  travel = 0;
                } else if (shown && travel >= 16) {
                  setState(() => shown = false);
                  travel = 0;
                }
              }
            }
            // RefreshIndicator and the scrollable still receive the notification.
            return false;
          },
          child: widget.child,
        ),
      ),
    ],
  );
}
