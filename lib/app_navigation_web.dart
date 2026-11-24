import 'dart:js_interop';

@JS('OTPandaNavigation')
external _Navigation get _navigation;

extension type _Navigation(JSObject _) implements JSObject {
  external JSString current();
  external void go(JSString route);
  external void listen(JSFunction callback);
  external void unlisten(JSFunction callback);
}

class AppNavigation {
  void Function()? onChange;
  late final JSFunction _listener;
  AppNavigation() {
    _listener = (() {
      onChange?.call();
    }).toJS;
    _navigation.listen(_listener);
  }
  String get current => _navigation.current().toDart;
  void go(String route) => _navigation.go(route.toJS);
  void dispose() {
    _navigation.unlisten(_listener);
    onChange = null;
  }
}
