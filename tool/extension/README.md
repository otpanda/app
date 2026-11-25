# Shared extension UI development package

This packages the existing fictional Flutter preview as an unpacked Manifest V3 extension. It is the unified repository home for the extension popup. Account connection is being implemented separately.

From the app root with Flutter3.50.1 and Node22:

```sh
bash tool/bootstrap.sh
flutter build web --csp --no-web-resources-cdn --base-href / --no-wasm-dry-run
node tool/extension/package.mjs
```

Load `build/extension-preview` as an unpacked extension in a development browser profile. The popup is390x600. All executable resources are packaged, no host permissions/content scripts/background worker are installed, and connect-src is self only. The web session bootstrap and Flutter web service worker are excluded. An immutable preview-only bridge returns unsupported for every operation. Sign-in/passkey reject explicitly; no credentials, storage or network are used. Shared production bridge behavior is unchanged.

The package intentionally keeps all renderer files until browser compatibility and popup lifecycle tests establish safe trimming. Do not widen API origins, add browser storage, page access, credentials or autofill in this packaging step. Those need separately reviewed boundaries. The old extension repository is retired; its complete history is preserved under archive/legacy-clients.

Run packager safety tests with `node --test tool/extension/package.test.mjs`. The optional headed Chromium lifecycle harness needs Playwright1.65.1 (tested), its Chromium channel, Xvfb and xdotool, and runs with `xvfb-run -a node tool/extension/popup-lifecycle.mjs`. It adds a shortcut only to a temporary test copy, opens the actual toolbar action, checks390x600 dimensions and accessibility-tree labels, closes with Escape and verifies a new popup target on reopening. It does not prove screenreader conformance or actual-popup keyboard search. The earlier extension-page keyboard check is a different test. No production shortcut or permissions are added.

The lifecycle check asserts popup dimensions and named AX nodes, exercises every preview bridge method, and fails on uncaught runtime/log errors. The stricter CSP uses self-only workers because Chrome rejects blob workers in MV3 extension pages. The generated loader call must be empty; inactive Flutter engine service-worker helpers remain packaged. Format-drift, missing-icon and source-symlink fixtures must fail packaging. This is still an untrimmed local development package, not a store submission. The headed harness uses --no-sandbox only in its throwaway development browser.

Failed validation leaves the previous package untouched: generation runs in a temporary directory and only validated output is renamed into place. The harness enables Network/Runtime/Log before reloading the popup and requires main.dart.js in observed startup requests; it checks startup plus interaction activity, not only post-attach silence. Generated bridge-tag drift is rejected too.

The separate optional-extension CI workflow runs packaging safety tests and a fresh CSP/no-CDN Flutter build, then uploads a seven-day development artifact. It does not publish to an extension store or change the web deployment. Real headed toolbar checks remain a local test, not a CI claim.
