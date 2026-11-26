// DEBUG fixture entrypoint only: build with `flutter build apk --debug --flavor google -t tool/android-lock-prompt/lock_fixture_main.dart`.
// Runs no app code (no app lock UI, no network), so only the native host under test runs. Never part of a release build.
import 'package:flutter/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
}
