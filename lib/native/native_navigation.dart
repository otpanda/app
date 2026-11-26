import 'package:material_ui/material_ui.dart';

/// Native account pages share a screen rather than browser URL history.
/// Keep that history here; real Navigator routes and dialogs still pop first.
class NativeNavigation extends StatefulWidget {
  const NativeNavigation({super.key, required this.builder});
  final Widget Function(BuildContext, String, ValueChanged<String>) builder;
  @override
  State<NativeNavigation> createState() => _NativeNavigationState();
}

class _NativeNavigationState extends State<NativeNavigation> {
  String route = 'codes';
  final history = <String>[];
  void navigate(String next) {
    if (next == route) return;
    setState(() {
      history.add(route);
      route = next;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: history.isEmpty,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && history.isNotEmpty) {
        setState(() => route = history.removeLast());
      }
    },
    child: widget.builder(context, route, navigate),
  );
}
