# Shared extension UI development package

This packages the existing fictional Flutter preview as an unpacked Manifest V3 extension. It is the unified repository home for the extension popup. This first section describes no-signin mode only; the separate authenticated candidate is documented below.

From the app root with Flutter3.50.1 and Node22:

```sh
bash tool/bootstrap.sh
flutter build web --csp --no-web-resources-cdn --base-href / --no-wasm-dry-run
node tool/extension/package.mjs
```

Load `build/extension-preview` as an unpacked extension in a development browser profile. The popup is390x600. All executable resources are packaged, no host permissions/content scripts/background worker are installed, and connect-src is self only. The web session bootstrap and Flutter web service worker are excluded. An immutable preview-only bridge returns unsupported for every operation. Sign-in/passkey reject explicitly; no credentials, storage or network are used. Shared production bridge behavior is unchanged.

The package intentionally keeps all renderer files until browser compatibility and popup lifecycle tests establish safe trimming. The no-signin preview never adds API origins, storage, credentials or autofill. The separately reviewed sign-in candidate below has its own explicit boundaries. The old extension repository is retired; its complete history is preserved under archive/legacy-clients.

Run packager safety tests with `node --test tool/extension/package.test.mjs`. The optional headed Chromium lifecycle harness needs Playwright1.65.1 (tested), its Chromium channel, Xvfb and xdotool, and runs with `xvfb-run -a node tool/extension/popup-lifecycle.mjs`. It adds a shortcut only to a temporary test copy, opens the actual toolbar action, checks390x600 dimensions and accessibility-tree labels, closes with Escape and verifies a new popup target on reopening. It does not prove screenreader conformance or actual-popup keyboard search. The earlier extension-page keyboard check is a different test. No production shortcut or permissions are added.

The lifecycle check asserts popup dimensions and named AX nodes, exercises every preview bridge method, and fails on uncaught runtime/log errors. The stricter CSP uses self-only workers because Chrome rejects blob workers in MV3 extension pages. The generated loader call must be empty; inactive Flutter engine service-worker helpers remain packaged. Format-drift, missing-icon and source-symlink fixtures must fail packaging. This is still an untrimmed local development package, not a store submission. The headed harness uses --no-sandbox only in its throwaway development browser.

Failed validation leaves the previous package untouched: generation runs in a temporary directory and only validated output is renamed into place. The harness enables Network/Runtime/Log before reloading the popup and requires main.dart.js in observed startup requests; it checks startup plus interaction activity, not only post-attach silence. Generated bridge-tag drift is rejected too.

The separate optional-extension CI workflow runs packaging safety tests and a fresh CSP/no-CDN Flutter build, then uploads a seven-day development artifact. It does not publish to an extension store or change the web deployment. Real headed toolbar checks remain a local test, not a CI claim.

## Sign-in mode (inactive by default)

`OTPANDA_EXTENSION_SIGNIN=1 OTPANDA_EXTENSION_API=https://<api-host> OTPANDA_EXTENSION_WEB=https://<pages-host>/app/ node tool/extension/package.mjs` adds the reviewed sign-in design. It fails closed without both origins. Optional: `OTPANDA_EXTENSION_REDIRECT_KEY` (default `chrome`) and `OTPANDA_EXTENSION_MANIFEST_KEY` (the public manifest key that fixes the Chrome extension ID; the API redirect allowlist must use that ID). Without the flag the package is unchanged.

Manifest additions in this mode include `identity`, `storage` and `scripting`, required API host access, optional HTTPS access, a module worker, and API/realtime/public-catalogue CSP destinations. No static content script or externally-connectable listener is installed. Dynamic scripts require an exact optional site grant.

Flow: the popup bridge messages the worker. The worker opens `chrome.identity.launchWebAuthFlow` at the Pages app with `#extension=1&challenge&redirect=<key>&state` (PKCE S256). The signed-in Pages user clicks Connect, which alone calls `/auth/extension/begin`; the Pages app then navigates to the allowlisted `chromiumapp.org` URI with `#code&state`. The worker checks the exact URI and state, generates a non-extractable ECDSA P-256 key, calls `/auth/extension/exchange`, and only then writes ONE extension-private IndexedDB record (device id, private key, public key). Access bearers, the PKCE verifier and state live only in `chrome.storage.session` (trusted contexts, default access level). Renewal signs `otpanda-extension-v1\nPOST /auth/extension/renew\n<device>\n<nonce>\n<expires>`. Only `invalid_grant` clears the record; network errors, 429 and 5xx keep it. Logout asks the server (signed) first and always cleans locally.

Real-browser test: `xvfb-run -a node tool/extension/e2e/e2e.mjs` (Playwright, Xvfb, openssl). It packages the extension, loads it in real Chromium with host-resolver mapping to a contract stand-in server (not the real API), and covers the identity window, window close, sign-in, IndexedDB key, worker stop, browser restart, transient and revoked renew, re-sign-in and logout.

Against the real API source: `OTPANDA_API_SRC=/path/to/api E2E_MANIFEST_KEY=<base64 public key> xvfb-run -a node tool/extension/e2e/e2e.mjs` runs the same checks with the API's own extension, read and entry-domains handlers (over the API's SQLite test shim, not a D1 runtime). The passkey/Google web sign-in is not exercised: the web session is minted by the API's own signup fixture. Add `E2E_REAL_BUILD=build/web` to package and load the compiled Flutter app instead of the stub page, and the run saves popup screenshots to /tmp.

## Stable Chromium candidate

The manual `Stable Chromium sign-in extension candidate` workflow builds a separate authenticated candidate artifact. It does not enable the production API gate, so production sign-in fails while that gate is off. This CI checks packaging; without an API checkout the optional API-source audit skips, and this workflow does not run the headed-browser proof. The ordinary preview workflow remains fictional and permission-free.

The checked-in public manifest key fixes unpacked Chromium ID `dahkpedanfmbhdocgmcchcdhifkbbien`, with exact redirect `https://dahkpedanfmbhdocgmcchcdhifkbbien.chromiumapp.org/`. It is a public identity anchor, not a signing secret or a Chrome Web Store identity guarantee. Do not replace it for an existing installed candidate without migrating the extension ID, installed sessions, redirect and origin allowlists together. A future store ID may differ and needs the same migration. The public key is clonable: ID/redirect pinning is not authentication proof. Explicit Connect, PKCE and the non-extractable device key remain required.

The dedicated compiled popup now has its own sign-in and scoped code view. Sign-in mode requests `identity`, `storage`, `scripting`, required API host access and optional HTTPS site access. Only exact matching sites requested from the popup may be granted; scripts register for granted candidate hosts, never for every HTTPS site. See `autofill/README.md`.

Production activation requires matching Worker configuration: `EXTENSION_AUTH_ENABLED=1`, `EXTENSION_REDIRECTS={"chrome":"https://dahkpedanfmbhdocgmcchcdhifkbbien.chromiumapp.org/"}`, and `EXTENSION_ORIGINS=["chrome-extension://dahkpedanfmbhdocgmcchcdhifkbbien"]`. Check current live configuration and reviewed authority before changing it. Rollback disables the flag; do not change signing or account data as a shortcut.

Qualification remains separate: the pinned ID and compiled popup passed real Chromium with API Worker/D1 and RealtimeHub DO in an isolated synthetic-identity fixture. That is not a real production Google/passkey login or store release. Before calling the candidate usable, verify the actual production Pages handoff, selected account, exchange, reads, realtime, restart and revocation. Installing it and granting optional sites in the user's browser remain separate user actions.
