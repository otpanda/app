import 'package:web/web.dart' as web;

import 'theme_choice.dart';

ThemeStore createThemeStore() => _Store();

final class _Store implements ThemeStore {
  static const _key = 'otpanda.theme-choice.v1';
  @override
  Future<ThemeChoice> read() async =>
      ThemeChoice.fromStorage(web.window.localStorage.getItem(_key));
  @override
  Future<void> write(ThemeChoice choice) async =>
      web.window.localStorage.setItem(_key, choice.storageName);
}
