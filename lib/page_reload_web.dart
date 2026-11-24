import 'dart:js_interop';

@JS('location')
external _Location get _location;

extension type _Location(JSObject _) implements JSObject {
  external void reload();
}

Future<void> _reload() async => _location.reload();

/// Reloads the whole browser page (web only).
const Future<void> Function() pageReload = _reload;
