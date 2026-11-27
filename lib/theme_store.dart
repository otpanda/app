import 'theme_choice.dart';
import 'theme_store_io.dart'
    if (dart.library.js_interop) 'theme_store_web.dart'
    as platform;

ThemeStore createThemeStore() => platform.createThemeStore();
