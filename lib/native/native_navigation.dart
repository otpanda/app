import 'package:material_ui/material_ui.dart';

class NativeNavigationHistory extends ChangeNotifier {
  String route = 'codes';
  final _history = <String>[];
  bool get atRoot => _history.isEmpty;
  void navigate(String next) {
    if (next == route) return;
    _history.add(route);
    route = next;
    notifyListeners();
  }

  void back() {
    if (atRoot) return;
    route = _history.removeLast();
    notifyListeners();
  }

  void clear() {
    route = 'codes';
    _history.clear();
    notifyListeners();
  }
}

/// Native account pages share a screen rather than browser URL history.
/// Keep that history here; real Navigator routes and dialogs still pop first.
class NativeNavigation extends StatefulWidget {
  const NativeNavigation({super.key, required this.builder, this.history});
  final NativeNavigationHistory? history;
  final Widget Function(BuildContext, String, ValueChanged<String>) builder;
  @override
  State<NativeNavigation> createState() => _NativeNavigationState();
}

class _NativeNavigationState extends State<NativeNavigation> {
  late final NativeNavigationHistory history =
      widget.history ?? NativeNavigationHistory();
  @override
  void dispose() {
    if (widget.history == null) history.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: history,
    builder: (context, _) => PopScope(
      canPop: history.atRoot,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) history.back();
      },
      child: widget.builder(context, history.route, history.navigate),
    ),
  );
}
