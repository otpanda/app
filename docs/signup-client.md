# Signup client preparation

Inactive preview only until final transport, independent review and live readiness
checks pass. The client accepts only exact RP/origin, UV-required discoverable
passkeys, bounded options and tab-bound PKCE/state. Callback fragments are removed
synchronously. The email proof never reaches app storage or a callback fragment.

Manual passkey action is required. Missing optional getTransports is an empty
list, not a fatal error after credential creation. Reload discards a ceremony;
return to the same starting-browser form to obtain a fresh bounded ceremony with
the existing browser-bound email proof. If the account/passkey was already made,
ordinary login is the recovery path, not account recreation. Another browser or
mail in-app browser cannot reuse the proof without the original cookie.

Clock validation remains strict. The UI exposes check-clock-or-restart rather
than weakening expiry or silently retrying. Signup tab context allows fifteen
minutes for mail arrival and proof entry, distinct from a two-minute passkey
ceremony. After verified attestation it refreshes the tab timestamp for a normal
five-minute PKCE callback. Server time remains authoritative for actual issuance.

All otpanda.github.io paths share the same RP/origin, including landing code.
Keep third-party scripts off this origin; never treat a project path as its own
security boundary. API signup pages must emit no-store, no-referrer, nonce CSP,
no third-party content and no request/query logging. PKCE challenge/state are not
raw credentials but still need redaction and callback cleanup.

Synthetic local Chromium WebAuthn tests verify cryptography and client encoding,
not hardware assurance, actual provider delivery, live cookies, CSRF or deployed
signup. Full transport browser journey remains required before activation.
