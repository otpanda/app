import 'package:material_ui/material_ui.dart';

import '../native_browser_fallback.dart';

/// Web and any non-dart:io target: never builds the native client.
Widget buildNativeRoot() => const NativeBrowserFallbackApp();
