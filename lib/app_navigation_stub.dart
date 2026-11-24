/// Native navigation keeps the same allowlisted page identifiers.
class AppNavigation {
  String current = 'codes';
  void Function()? onChange;
  void go(String route) {
    current = route;
    onChange?.call();
  }

  void dispose() {
    onChange = null;
  }
}
