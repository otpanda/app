# Native client request/response contract (otpanda-native-v1)

Source of truth for each line: client = `lib/native/native_auth.dart`, `native_handoff.dart`,
`native_signing.dart`; server = API patch `native-0039-google-stepup-8a6a1d1-1d8f5ede`
(`src/native-http.js`, `native-sessions.js`, `native-google.js`). The server header says
"not mounted": nothing below is live until primary mounts it. Shared executable vector:
`test/fixtures/native-vector.json` (same file as the API's `test/native-vector.json`).

## Transport rules (all token routes)
- API origin `https://otpanda-api.abrahammurciano.workers.dev`. POST only, JSON, header
  `content-type: application/json` exactly, body <= 4096 bytes, exact key set (no extras).
- No cookies, no CORS, and the request must carry NO `Origin` header and no query string
  (server answers 403). Success bodies are `no-store`.
- Errors: `{"error": ...}` with 400 invalid_request, 401 invalid_grant, 403 forbidden,
  409 browser_required (Google path only), 429 rate_limited, 503 unavailable.
  Client mapping is in `NativeAuth._fail`.
- Rate limits: 30 per client address per route per window; 20 per device id for
  challenge/renew/logout.

## Browser path (the only path on fdroid)
1. App opens `https://otpanda.github.io/app/#native=1&challenge=C&state=S` in a Custom Tab
   (`pagesNativeLaunchUrl`). C and S are 43-char base64url; C = base64url(SHA-256(verifier)).
2. Pages (NOT IMPLEMENTED, see unresolved) parses the fragment with
   `tool/native-launch-intent.js`, signs the user in if needed, then navigates to
   `GET {API}/auth/native/approve?challenge=C&state=S&redirect_uri={API}/app-return`.
3. Approve page shows an explicit Continue. POST (form, same-origin, CSRF bound to the
   intent) rotates the first-party web cookie and 303s to
   `{API}/app-return#code=CODE&state=S` (or `#auth=restart&state=S` when no grant).
4. Android verifies the App Link, the app calls `parseAppReturn`: https, API host, path
   `/app-return`, no query, fragment with exactly unique `code` and `state`, state equal
   (constant-time) to the one it generated.
5. `POST /auth/native/exchange` body keys `code, redirect_uri, renewal_key, verifier`
   (`redirect_uri` = `{API}/app-return`, `renewal_key` = base64url of the new P-256 key,
   `encodeRenewalKey`). 200: `{device_id, access, access_expires_at}`; else 401 invalid_grant.
   Server: code lives 60 s, one use, refused before spend if redirect or key is invalid.
6. Client stores device id, then commits the pending Keystore key (order matters).

## Google path (google flavor only)
- `POST /auth/native/google/begin` with an EMPTY body -> `{nonce, expires_at}` (nonce lives
  5 min, one use). 503 when no audience is configured.
- Credential Manager ID token with that nonce, then `POST /auth/native/google/complete`
  `{id_token, renewal_key}` -> 200 same shape as exchange, or 409 browser_required
  (anything beyond a linked identity or a brand new account, or extra-verification
  protection on). Client then falls back to the browser path.

## Renewal, logout
- `POST /auth/native/challenge` `{device_id, purpose}` (`renew|logout`) ->
  `{device_id, nonce, expires_at}` (nonce lives 60 s).
- Signed message (exact UTF-8): `otpanda-native-v1\nPOST /auth/native/<purpose>\n<device_id>\n<nonce>\n<expires_at>`;
  signature = ECDSA P-256 SHA-256 over those bytes, sent as raw r||s base64url (86 chars).
  Keystore emits DER; `ecdsaDerToRaw` converts.
- `POST /auth/native/renew` `{device_id, expires_at, nonce, signature}` -> 200
  `{access, access_expires_at}`. Access lives 5 min. 401 once is retried with a new
  challenge; a second 401 is surfaced as invalid_grant (the client treats it as paused, not
  signed out, and deletes nothing).
- `POST /auth/native/logout`: either the signed body above (purpose logout) or, with an
  `Authorization: Bearer` access token and an empty body. 204; local material is deleted
  only after the 204.
- Limits: access/idle 30 days, 8 outstanding challenges, 8 exchanges, 64 access, 50 devices.

## Unresolved, owned elsewhere (no values invented here)
1. Pages: nothing parses `#native=1` yet and nothing sends the browser on to the approve URL.
   Needs a hunk in `tool/session-bootstrap.js` or the app entry: keep the intent across
   sign-in, then `location.assign(nativeApproveUrl(intent))`. Owner: primary.
2. Mounting `createNativeHttp` and the 0039 migration in the API router. Owner: primary/API.
3. `assetFingerprints` for `/.well-known/assetlinks.json` (final signer SHA-256, format
   `AA:BB:...` 32 bytes) and the step-up `androidOrigins`. Both fail closed while empty.
   Owner: primary (signer provenance exists, final package association not yet checked).
4. Google audiences for `NativeGoogle` and the Android OAuth client registration. This one
   needs the user's approval and is not needed until 1 and 2 exist.
5. Client gate `NATIVE_SIGNIN` stays off until 1 to 3 are proven.
