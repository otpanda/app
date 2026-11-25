# OTPanda app

Unified Flutter client for Android, web, Linux, Windows, macOS and the browser extension popup. API and landing page are separate services, not client repositories.

Canonical web app: https://otpanda.github.io/app/

The web app supports real account sign-in, codes and entry management. Native Android qualification is in progress. Do not treat build success as provider sign-in, App Link or native feature-parity proof. The extension packaging and browser integration are under tool/extension; autofill integration is not yet enabled.

Legacy web and extension repository histories and issue records are preserved under archive/legacy-clients. They are historical inputs, not alternate clients to develop or deploy.

## Build

Use Flutter 3.50.1. Run `bash tool/bootstrap.sh`, `flutter test` and
`flutter build web --base-href /app/ --no-wasm-dry-run`. Platform host folders
are generated from the pinned Flutter version during this first scaffold. The
identifier `org.otpanda.development.otpanda_client` is development-only, not the
selected release identity. Host folders should be checked in once stable platform
identity/adapters are configured. Never store local SDK paths or keys in Git.

The standard APK will use native-first Google login with browser fallback.
A separate FLOSS F-Droid flavor is allowed if required; OS-level auth there is
preferred but unverified. Flutter does not remove that dependency constraint.
SMS collection remains opt-in and separate from ordinary client login.

CI checks web and Android on GitHub Actions. Successful main builds deploy the fictional-data Flutter preview to https://otpanda.github.io/app/. This is not a working cloud account or a trusted signed release. CI also produces a web artifact and an ARM64 development debug APK. The debug APK uses the development identifier and a temporary runner debug key, not a stable update/sign-in identity. It is for compile checks and development only. Desktop CI targets still need their platform checks. Dedicated
release signing/key custody and stable package identity must be settled before
trusted downloadable GitHub Releases. No production signing key is generated.

### Shared preview progress

Responsive Otty branding, compact received codes, owned-entry create/edit/delete and source revoke confirmation are implemented with fictional data. Shared entries remain read-only. Source revocation changes a fictional source only, not a real upload connection or the demo code cards. The management read/write contracts have synthetic tests, but no platform network transport or live session integration yet. Native ARM64 debug compilation through source/access previews has passed locally; this is not a signed release or device-runtime verification.

## Account/security and branding preview
The account icon opens a clearly labelled setup preview with sample recovery readiness and last-option removal warnings. No credentials are collected or enrolled.24 Flutter tests cover preview behavior and320px layouts.

`tool/brand_hosts.py` runs after reproducible host creation. It applies the approved Otty mascot to favicon/PWA/apple-touch, Android legacy/adaptive launchers, Windows/macOS icons, display titles and social-preview image. The PWA id/start/scope are `/app/`; descriptions explicitly state development-preview limitations. Public application identifiers and signing identity remain development-only and are not changed by branding. Generated desktop packaging still needs platform build verification. Browser/PWA/social services may cache old metadata.
