# Offline TOTP: import and export formats (pure Dart, inactive)

Requested by the user on Nov 24 2026 12:13 IST: platforms with secure storage keep code-generation keys locally and synced with the cloud so TOTP works offline; keys can be imported from and exported to other TOTP apps; export needs strong re-authentication.

This slice is only the format layer. It is not imported by the app, has no storage, no network, no UI and no key custody. `lib/offline_totp.dart` exports it.

## What exists
- `OtpAccount`: immutable TOTP entry (issuer, account, algorithm SHA1/256/512, digits 6/8, period 1..86400, secret 10..128 bytes). `toString`, errors and previews never contain the secret. `secretBytes()` returns a copy.
- `parseOtpauthUri` / `encodeOtpauthUri`: Google Authenticator Key URI. Strictness mirrors the API's `totp-uri.js`: no whitespace, only known parameters, no duplicates, issuer prefix must equal issuer parameter, HOTP/MD5 refused; digits 6, 7 or 8.
- `parseMigrationUri` / `assembleBatches` / `encodeMigrationUris`: `otpauth-migration://offline?data=` (MigrationPayload protobuf). Multi-QR batches must share batch id, size and version with each index exactly once.
- `previewImport`: metadata-only list with duplicate flags (against existing entries and within the batch).

## Compatibility and strictness decisions
- Key URIs with parameters outside `secret, issuer, algorithm, digits, period` (for example `image`, `lock`, `counter`) are refused, same as the API's `totp-uri.js`. Some apps emit extras; relaxing this is a deliberate product decision, not done silently.
- Legacy Google entries with no issuer field and a name like `Issuer:account` are split into issuer and account. Names with several colons, an empty side, or a colon name that contradicts a separate issuer are refused.
- Labels refuse control, bidirectional, zero-width, soft hyphen, BOM and line/paragraph separator characters (stricter than the API parser, which only checks a smaller set; consider aligning the API). Ordinary non-ASCII text is allowed.
- `previewImport` duplicate flags are advisory. Nothing is dropped automatically; the caller and the user decide.

- Migration payload supports explicit version 1 only; missing, zero and unknown versions are refused. Duplicate singular parameter fields 1..6 and payload metadata fields 2..5 are refused. Repeated account field 1 is expected.
- Literal plus in migration base64 must be percent-encoded; query decoding treats a raw plus as a space and fails closed. Duplicate preview detection compares issuer/account labels only and is advisory, never seed equality.

## Deliberate limits
- The migration format carries no period and no 7-digit mode (7 is valid in the model and goes out as Key URI, Aegis or Bitwarden). Import assumes 30 s. Export refuses any account it cannot carry exactly (`notRepresentable`) instead of changing it; use the Key URI for those.
- HOTP, MD5 and unknown types are refused, not downgraded.
- Protobuf reader uses exact 64-bit (BigInt) varints so the Dart VM and compiled JS agree. Tags, lengths and enum values above 32 bits are malformed (an earlier version shifted the tag, and on JS a tag above 2^32 aliased a real field while the VM ignored it; a test demonstrated this on JS before the fix). Unknown fields below that are skipped, groups are refused, batch size is bounded (50) and input length (16 KB). Negative int32 batch ids (10-byte varints) parse.
- Export never emits a URI longer than the decoder accepts: oversized batches are split and re-encoded with the right batch count, and a single account too large is refused.
- Encoders return secrets. They must only be called after a strong re-authentication step bound to the exact export action (same pattern as the `passkey:add` step-up in API). That gate is not part of this slice. Exported text and QR images must not be logged, cached or kept in storage after display.

## Not done (needs source-grounded design or the user)
- Secure local storage per platform (Android Keystore handle model is in `tool/offline-totp`; web has no equivalent secure storage), sync protocol, versions, tombstones, device revocation limits (see `tool/offline-totp/README.md`).
- Export re-authentication endpoint and UI, QR scan/render, file formats of specific other apps (Aegis, 2FAS, Bitwarden, etc.), API seed import route.

## Limits of what this proves
- Dart strings and byte lists are not guaranteed to be erased, and `secretBytes()` copies are the caller's to handle. Nothing here makes a secret non-exportable; non-extractable keys are a platform keystore property (see `tool/offline-totp`), not something this layer provides.
- Secure storage exists only on some platforms. Whether the browser build holds offline keys at all is not decided here; the user's condition (platforms with secure storage) scopes it, and the browser has no equivalent of a hardware-backed non-extractable store.

## Evidence
`test/offline_totp/offline_totp_test.dart` (26 tests) passes with `flutter test test/offline_totp`, and the earlier archive whole-repo suite passed, on Flutter 3.50.1 (the version pinned in `.github/workflows`). `flutter analyze` is clean. The archive tests also passed compiled to JS on Node; current qualification is reported separately. Migration fixtures come from an independent Python protobuf encoder, not this code. Mutants removing the base32 pad check, the HOTP check, batch index uniqueness, the export representability check and the issuer-conflict check each fail a test. Synthetic secrets only (RFC 6238 key and arbitrary bytes).

## Import policy (units 1 and 2, inactive)
- Defaults are visible, not silent: `OtpAccount.assumed` lists parameters the source lacked (period for every Google migration account, an unspecified Google algorithm or digit count, anything absent from a Key URI or Aegis entry). `withParameters` edits them and clears the matching assumption. `OtpAssumption.encodeAll/decodeAll` give a strict storage form; the wiring must persist it with the saved account.
- `parseMigrationUri(skipUnsupported: true)`, `parseOtpauthList` and `parseAegisPlainVault` import what they can and return `SkippedEntry` items (position, reason, and a display-safe issuer and account name for local preview only; toString never prints them). Container-level damage is never skipped past. HOTP, MD5, unknown algorithms, Steam, mOTP, Yandex and encrypted files are explicit gaps, never converted.
- `isMigrationRepresentable` is the one rule for the Google format (30 s, 6 or 8 digits). `planMigrationExport` routes the rest to Key URIs or the Aegis vault.
- Aegis plain vault: import and export, checked against Aegis docs/vault.md and the structure of its published plain test vault. Encrypted Aegis, 2FAS, Bitwarden and other formats are not done (see the separate encrypted-formats proposal).
- 2FAS (`parseTwoFasBackup`, plain only; schema read from Aegis's importer, not a vendor spec; no export) and Bitwarden (`parseBitwardenJson/Csv`, `encodeBitwardenJson/Csv`, plain only; shape from Bitwarden's help page and the layout of Aegis's published Bitwarden sample) skip HOTP, Steam, MD5 and unknown values per entry with a reason. Bare Bitwarden secrets import with every parameter marked assumed.
- 7-digit TOTP is valid in the model (6, 7 or 8). The Google migration format cannot carry it, so it routes to Key URI/Aegis/Bitwarden. The API still rejects 7 (`totp-uri.js` and `totp-seeds.js`); until that changes, a 7-digit import must not be committed to the server.
- Metadata not carried: notes, icons, groups/folders and favorites are dropped on import and written empty on export; the UI must say so.
