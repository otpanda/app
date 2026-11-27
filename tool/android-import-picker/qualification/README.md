# Import picker installed qualification (debug only, synthetic) - UNRUN until an API 34 emulator executes it

Question: with the real Flutter engine, the production `ImportPickerHost` and the REAL system document picker, does a legitimate
selection open exactly once after the picker backgrounds the app, and is a stale selection (caller engine retired, or caller
process killed while the picker survives) never opened and never handed to a later request?

Separation: everything here is debug source set. `install.py` copies `debug/*.kt` into `android/app/src/debug/...` and edits only
`android/app/src/debug/AndroidManifest.xml`. Production code (`DocumentImport.kt`, `host/ImportPickerHost.kt`) has no fixture hooks.
`check_release.py APK` fails if any fixture marker is in a release artifact (run it on a release build; kept out of `run.sh`).

What runs (`run.sh OUT`, booted API 34 google_apis x86_64 emulator, repo root after `tool/bootstrap.sh`):
- `PickerFixtureActivity` extends the real `MainActivity`, registers the production `ImportPickerHost` itself unless the app already
  did (primary's MainActivity must have `open class MainActivity`, as in the seed fixture), and adds the fixture-only channel
  `pickfx/driver` (scenario, persisted phase, fixed-label marks and checks, lifecycle counters).
- `SyntheticDocumentsProvider`: a real `DocumentsProvider` with one root, "OTPanda picker fixture", and documents a (`synthetic-a`),
  b (`synthetic-b`), bad (invalid UTF-8), big (2 MiB + 1). It logs `OPEN <id> <n>` for every open, never names, URIs or content.
- `fixture_main.dart` drives the real `AndroidImportPicker`. `drive.py` presses the real picker UI through uiautomator (hamburger,
  provider root, tap document, BACK) and `verify.py` judges the logs.

Scenarios and what each proves:
- normal: three picks. a opens once and is delivered, with `onStop` observed before the result (legitimate picker background, no
  cancel on pause). A second `pick()` while pending is `busy` and does not drop the pending result. b delivered. BACK gives null.
  Provider opens: a=1, b=1.
- errors: bad gives `notText`, big gives `tooLarge`, both through the real provider.
- rotation: real user rotation while the picker is open. Accepts either outcome and checks it is consistent: engine survived (text a,
  a opened once) or engine retired (new Dart run sees phase "picking", a never opened).
- recreate: a configuration change (font scale) while the picker is open, same either-or check.
- stale_recreate: a real configuration change (font scale) is made while the picker is open. Observed on the API 34 image: the
  stopped caller is recreated only when it next resumes, i.e. as the picker returns, so the old result is delivered to the NEW
  engine (not retired before the selection). a must never be opened (opens a=0) or reach the new engine's request, the first
  engine must show cleanup and a restored create, and a fresh pick of b then works (b=1). If no recreation happens, the old pick
  completes and the fixture fails with stale_old_engine_gone false. `always_finish_activities` via `settings put` and a font scale
  wait for retirement-before-selection both proved unsupported (runs 46028325228, 46030533362).
- stale_kill: `run-as app.otpanda kill -9 <pid>` (real SIGKILL of the debuggable app; `am kill` left a picker-hosting process
  alive in that run) while the picker is up. The harness fails if the pid survives, records `killed_before_selection`, then selects
  a, restores, and requires a new pid. a never opened; a fresh pick of b works (b=1).

Not covered: a NEW process beginning its own picker while the OLD picker is still open (overlap). Android's task restore order decides
whether that can be driven, so no claim is made. The durable allocator is unit-tested for it (JVM). Also not proven: other pickers,
real cloud providers, hardware. The allocator never reuses a request code (monotonic, durable, 1024 launches per install, then "unavailable" until app data is cleared), so it does not rely on exactly-once result delivery; the fixture does not test duplicate delivery.

Local checks that DO run without a device: `python3 uinav_test.py`, `verify_test.py`, `check_release_test.py`; the Kotlin fixture
compiles against android.jar, the Flutter embedding jar and androidx.lifecycle-common (with a stub `app.otpanda.MainActivity`);
`flutter analyze` on `fixture_main.dart`.

Isolation: every scenario starts with `isolate()` (force-stop the app and com.android.documentsui, default font scale, rotation and
always_finish settings, HOME) and retries the launch once. An app that never logs `ACT create` is a harness failure.
