# Shared extension UI development package

This packages the existing fictional Flutter preview as an unpacked Manifest V3 extension. It does not replace the extension repository or connect an account.

From the app root with Flutter3.50.1 and Node22:

```sh
bash tool/bootstrap.sh
flutter build web --csp --no-web-resources-cdn --base-href / --no-wasm-dry-run
node tool/extension/package.mjs
```

Load `build/extension-preview` as an unpacked extension in a development browser profile. The popup is390x600. All executable resources are packaged, no host permissions/content scripts/background worker are installed, and connect-src is self only. The web session bootstrap and Flutter web service worker are excluded. An immutable preview-only bridge returns unsupported for every operation. Sign-in/passkey reject explicitly; no credentials, storage or network are used. Shared production bridge behavior is unchanged.

The package intentionally keeps all renderer files until browser compatibility and popup lifecycle tests establish safe trimming. Do not widen API origins, add browser storage, page access, credentials or autofill in this packaging step. Those need separately reviewed boundaries. The existing extension remains intact until replacement parity.

Run packager safety tests with `node --test tool/extension/package.test.mjs`. The optional headed Chromium lifecycle harness needs Playwright1.65.1 (tested), its Chromium channel, Xvfb and xdotool, and runs with `xvfb-run -a node tool/extension/popup-lifecycle.mjs`. It adds a shortcut only to a temporary test copy, opens the actual toolbar action, checks390x600 dimensions and accessibility-tree labels, closes with Escape and verifies a new popup target on reopening. It does not prove screenreader conformance or actual-popup keyboard search. The earlier extension-page keyboard check is a different test. No production shortcut or permissions are added.

The lifecycle check asserts popup dimensions and named AX nodes, exercises every preview bridge method, and fails on uncaught runtime/log errors. The stricter CSP uses self-only workers because Chrome rejects blob workers in MV3 extension pages. The generated loader call must be empty; inactive Flutter engine service-worker helpers remain packaged. Format-drift, missing-icon and source-symlink fixtures must fail packaging. This is still an untrimmed local development package, not a store submission. The headed harness uses --no-sandbox only in its throwaway development browser.

Failed validation leaves the previous package untouched: generation runs in a temporary directory and only validated output is renamed into place. The harness enables Network/Runtime/Log before reloading the popup and requires main.dart.js in observed startup requests; it checks startup plus interaction activity, not only post-attach silence. Generated bridge-tag drift is rejected too.

The separate optional-extension CI workflow runs packaging safety tests and a fresh CSP/no-CDN Flutter build, then uploads a seven-day development artifact. It does not publish to an extension store or change the web deployment. Real headed toolbar checks remain a local test, not a CI claim.

## Sign-in mode (inactive by default)

`OTPANDA_EXTENSION_SIGNIN=1 OTPANDA_EXTENSION_API=https://<api-host> OTPANDA_EXTENSION_WEB=https://<pages-host>/app/ node tool/extension/package.mjs` adds the reviewed sign-in design. It fails closed without both origins. Optional: `OTPANDA_EXTENSION_REDIRECT_KEY` (default `chrome`) and `OTPANDA_EXTENSION_MANIFEST_KEY` (the public manifest key that fixes the Chrome extension ID; the API redirect allowlist must use that ID). Without the flag the package is unchanged.

Manifest additions in this mode only: permissions `identity` and `storage`, one host permission for the API origin (needed because the token routes send no CORS headers; this is not page access), a module background worker, and `connect-src 'self' <api>`. No content script, no `externally_connectable`, no page host permission.

Flow: the popup bridge messages the worker. The worker opens `chrome.identity.launchWebAuthFlow` at the Pages app with `#extension=1&challenge&redirect=<key>&state` (PKCE S256). The signed-in Pages user clicks Connect, which alone calls `/auth/extension/begin`; the Pages app then navigates to the allowlisted `chromiumapp.org` URI with `#code&state`. The worker checks the exact URI and state, generates a non-extractable ECDSA P-256 key, calls `/auth/extension/exchange`, and only then writes ONE extension-private IndexedDB record (device id, private key, public key). Access bearers, the PKCE verifier and state live only in `chrome.storage.session` (trusted contexts, default access level). Renewal signs `otpanda-extension-v1\nPOST /auth/extension/renew\n<device>\n<nonce>\n<expires>`. Only `invalid_grant` clears the record; network errors, 429 and 5xx keep it. Logout asks the server (signed) first and always cleans locally.

Real-browser test: `xvfb-run -a node tool/extension/e2e/e2e.mjs` (Playwright, Xvfb, openssl). It packages the extension, loads it in real Chromium with host-resolver mapping to a contract stand-in server (not the real API), and covers the identity window, window close, sign-in, IndexedDB key, worker stop, browser restart, transient and revoked renew, re-sign-in and logout.
