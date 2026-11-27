# Transfer codes: batch import and sealed export (API contract proposal)

Status: batch source is implemented in isolated API commit1c19af4, not registered. Export remains a source proposal, not registered. The client seams are `ImportSaver` and `SeedExportSource` in `lib/transfer/`. Modeled on seed-sync enroll v2 (action digest, one-use token, passkey step-up) and `seed-sync-seal.js` (sealed batch to a client ephemeral key).

## Why
- Today every account add is its own passkey step-up (`/v1/manage/totp/begin`, then `/v1/manage/totp`). A 20-account Google export would need 20 prompts and could commit partly.
- There is no export route. Server comment: "never replace/export a seed". Non-extractable native custody (Android Keystore HMAC) cannot be an export source.

## 1. Batch import: `totp/batch-begin`, `totp/batch-finish` (session auth, owner only)
begin body, exact keys: `{ items: [{label, account, secret, catalogId?}], batchNonce }`
- Limits: initial API transaction accepts 1..50 selected items, body cap proposal 64 KiB. The review can collect up to 1000 entries, but MUST NOT split one approved import into independent commits. Before exposing larger saves, qualify one whole-plan transactional staging design within current D1 limits. Until then show the actual supported selection limit before confirmation; never silently truncate or chunk. `secret` is the same otpauth URI string the single add already accepts (algorithm, digits, period carried in it), validated per item with the existing `parseTotpUri`. Any invalid item rejects the whole begin (400 `invalid_request`, no item index or secret echo).
- Canonical payload: `["totp-batch-import-v1", ownerId, deviceId, generation, batchNonce, [[label, account, catalogId|null, sha256hex(secretUri)] ...in request order]]` as JSON. Action digest = sha256 of that string. Secrets enter the digest only as hashes, so the step-up ceremony row never stores a secret.
- Step-up: `passkeys.begin({purpose:'step-up', ownerId, binding, action:'totp-batch-import:'+digest})`; binding = hash of owner and device and digest, as in `seedSyncEnrollBinding`.
- Response: the usual `{token, options, expiresAt}`. The server also stores the validated items sealed with the existing `getSeedCipher` keyed by ceremony id, with the same expiry (120 s), OR the finish request re-sends the items (preferred: stateless, finish body carries `items` again and the server recomputes the digest; mismatch is refused). Proposal: re-send, cap 64 KiB.
finish body, exact keys: `{ items, batchNonce, token, response }`
- Verify assertion with the same binding and action; require generation, owner and device unchanged. Insert all entries and seeds in ONE D1 batch with a `tx_assert` guard so a failure rolls back everything. Reply `{entryIds:[...]}` in request order, 201.
- Existing passkey service consumes the token before D1 commit, fail closed. Repeated exact committed nonce returns stored200; changed nonce contents409; spent ceremony without saved outcome403 requires fresh proof for the same nonce. Do not claim ceremony consumption and data commit are one transaction.
- Outcome semantics for the client: 201 with the exact number of entryIds is `saved`; 400/409/401 definitive refusals are `notSaved`; timeouts or lost replies are `unknown` (client says refresh and check; never auto retry because an owner can end up with duplicates).
- Duplicates: the server does not dedupe by label. The client already skips same issuer+account. A replay after unknown can still duplicate, so finish takes a required client `batchNonce` (random 128-bit) stored per owner until account deletion; second finish with the same nonce returns the first result without inserting. Implemented table uses permanent replay tombstones, no age pruning.

## 2. Sealed export: `totp/export-begin`, `totp/export-finish` (OWNER only)
begin body: `{ entryIds?: [...], ephemeralKey }`. If entryIds is omitted, resolve every owned entry at BEGIN and bind that exact sorted set and each seed version into the action digest. Finish must not expand this set. Shared-in entries are never exported; other owners' seeds are refused.
- `ephemeralKey` is the client's ECDH P-256 public key (as in seed-sync batch).
- Canonical action: `["totp-export-v1", ownerId, deviceId, generation, sorted entryIds, sha256hex(ephemeralKey)]`. Step-up passkey `userVerification: required`, action `'totp-export:'+digest`. Fresh each time, no remembered grant, 120 s expiry.
finish body: `{ token, response }`
- Verify the assertion, claim the token once. Seal each seed with `sealBatch` to the client ephemeral key (AAD binds owner, entry, token digest). Response `{serverPublicKey, entries:[{entryId, label, account, issuer, algorithm, digits, period, sealed}]}`. `Cache-Control: no-store`. Do not log bodies. Rate limit a few per hour per owner. Consider a push or email notice to the owner on every export.
- Owner-only SQL: `WHERE e.owner_id = ?owner`. A delegated or machine session, or a session whose generation changed, is refused.
- Client: generates the ephemeral key per attempt, decrypts in memory, builds `OtpAccount`s, hands them to `ExportCodesPage`; zeroes buffers on cancel, dispose and when the app leaves the foreground (page already drops the QR on pause). Never writes to disk, clipboard or logs. Plain-file or otpauth-list export is a separate, explicit user action with a warning and is not part of this route.

## 3. Client checks that already exist as tests
- Google export preserves custom periods in OTPanda field 15; Google uses its own default when it ignores that field. No extra compatibility approval or alternate format is required. Seven-digit interoperability is not qualified; current server and custody support six, seven and eight digits.
- Export QR parts stay under 1800 characters and decode back through `parseMigrationUri`/`assembleBatches`.
- Review shows every account before any save, skips duplicates by default, blocks multi-account save unless the saver reports `atomic`.

## Open items for primary
- Batch finish re-sends exact items and required nonce; permanent owner-bound nonce table is implemented and qualified on real D1.
- Decide the export notice (email or in-app) and the rate limit.
- Android and web differ in which saver they get; web has its own passkey bridge (`browser_session_web.dart`) that needs the same two routes.

## Google export policy
Google accepts the tested unknown period field and ignores it. Preserve the true period in OTPanda field 15 so OTPanda round-trips it, while Google uses 30 seconds. Import without the field uses 30 seconds and marks the assumption. Compatibility notes are lightweight and nonblocking, not an extra approval or alternate-format demand. Current server/custody support six, seven and eight digits. Field16 writes original7 with known Google field5 six fallback; Google field16 behavior is unverified.

## File formats
`detectImportFile`/`parseImportFile` detect otpauth list, Aegis plain, 2FAS plain and Bitwarden JSON/CSV by content. `exportFileText` writes otpauth list, Aegis plain and Bitwarden JSON/CSV. Notes, icons, folders and favorites are dropped and the UI says so. The shell supplies `saveFile` and `newUuid`. Plain files hold secrets: save only after owner re-auth, never log or copy them. Encrypted variants are not implemented. The current API supports7 digits.

## Period extension (OTPanda field 15)
Google export writes the true TOTP period in OtpParameters protobuf field 15 (varint, 1..86400) when it is not 30. Google ignores it and shows 30 s (user test Nov 26, synthetic QR). OTPanda import reads it back exactly and no longer marks the period as assumed. A duplicate field 15, a non-varint wire type or an out-of-range value refuses the whole payload. The encoder stays strict unless `periodExtension: true`. 7-digit keys use opt-in OTPanda field16, retaining field5 six enum as compatibility fallback. Actual Google acceptance/ignore/display behavior for field16 is not verified.

## Execution constraints for export source
- Primary owns runtime activation and deploy. Return additive source, migration0065 if storage is needed, tests, and exact wire contract. API base1c19af4. Do not alter production worker registration.
- Resolve exact owned set and seed versions at BEGIN, persist frozen encrypted attempt state if finish omits them; no expansion at finish. Bind ephemeral key and every semantic selection value.
- Use real existing seed cipher and sealed ECDH/AES-GCM behavior; include tamper, cross-owner, revoked-session, changed-version, stale/replayed ceremony and ephemeral-key substitution tests. Missing seed-sync-seal on this branch is a source-recovery task, not permission for plaintext fallback.
- No email, notification, spending or new account effects. Owner-only strong fresh proof; outcome ambiguity must never claim failure or silently retry with a new export attempt.
