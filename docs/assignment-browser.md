# Inactive browser assignment composition

Default production remains read-only for incoming-code assignment. `assignmentEnabled` defaults to false, `brand_hosts.py` does not include assignment factories, and API runtime/bootstrap activation is a separate gate. No real mailbox or phone source is connected by this increment.

The optional host builds `tool/assignment-controller.js` and `tool/assignment-transport.js` with `node tool/build-assignment-host.mjs OUTPUT.js`. Load that classic bundle before `session-bootstrap.js` only in an explicitly approved host. The session closure passes ephemeral access and generation callbacks. Flutter receives the server summary and status, never ceremony tokens. No assignment data is written to persistent storage.

A server summary precedes the deliberate passkey gesture. It names the target/account, active recipient and automation-recipient counts, and irreversible disclosure. Finish is submitted once. A lost/refused response becomes unknown, followed by at most four bounded status reads; missing/expired status is not treated as proof that no write happened. Only the server's authoritative `not-assigned` receipt permits dismissal/new confirmation. A retained retired_at tombstone and atomic expiry transition block any stale in-flight finish from committing. Missing rows, legacy expiry, transport failure and401 remain unknown. Pending/unknown blocks replacement, including after closing and reopening the dialog. Logout suppresses late UI results and pre-send assertions, not a sent server write. A fresh session must review current entry state before a new assignment.

Checks:

```
node --test test/assignment*.mjs test/session_bootstrap_test.cjs
flutter analyze
flutter test
bash tool/bootstrap.sh
flutter build web --target test/fixtures/assignment_browser_main.dart --base-href /app/ --no-wasm-dry-run
node tool/assignment-browser-check.mjs
```

The final script requires Playwright and its Chromium. `PLAYWRIGHT_MODULE` may name an installed module entrypoint; `ASSIGNMENT_EVIDENCE_DIR` defaults to /tmp. It routes all app/API responses to local synthetic fixtures while retaining the canonical HTTPS origin. Chromium's virtual CTAP2 authenticator makes an actual WebAuthn assertion. It exercises the compiled Flutter dialog through the real optional factories, session closure and Dart interop, checks zero writes before confirmation, exactly one finish, successful outcome and lost-response reconciliation, and captures 360px screenshots. This is browser runtime proof, not physical-device or production-server proof. Build the normal entrypoint again before production publication.

Remaining release gates: reviewed API runtime merge and activation, production auth/bootstrap approval and verification, physical passkey/device checks, and real-source authorization. Android durable enrolled-device recovery is separate and not completed here.
