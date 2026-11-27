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
- stale_recreate: `always_finish_activities=1`, so the caller is destroyed when the picker opens. The old selection a arrives at a
  new engine: it must never be opened (opens a=0). Then a fresh pick of b works (b=1). Requires a restored caller and a second engine.
- stale_kill: `am kill` of the app process while the picker is up (harness fails if the process survives), then selection a
  and restore. a never opened; a fresh pick of b works; the pid differs. This is the process-death-with-surviving-picker case.

Not covered: a NEW process beginning its own picker while the OLD picker is still open (overlap). Android's task restore order decides
whether that can be driven, so no claim is made. The durable allocator is unit-tested for it (JVM). Also not proven: other pickers,
real cloud providers, hardware. The allocator never reuses a request code (monotonic, durable, 1024 launches per install, then "unavailable" until app data is cleared), so it does not rely on exactly-once result delivery; the fixture does not test duplicate delivery.

Local checks that DO run without a device: `python3 uinav_test.py`, `verify_test.py`, `check_release_test.py`; the Kotlin fixture
compiles against android.jar, the Flutter embedding jar and androidx.lifecycle-common (with a stub `app.otpanda.MainActivity`);
`flutter analyze` on `fixture_main.dart`.
