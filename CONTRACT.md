# Shared session contract

`lib/session_contract.dart` is a transport-independent read contract for the
integrated entry API. It is not wired into the demo UI and does not enable login.
A platform adapter must supply an authenticated session transport. Do not use an
automation token as a substitute for session authentication.

The three current routes are session, entries and active-codes under
`/v1/manage/`. They match the API's integrated entry application, rather than
its older service-scoped foundation. Unknown-entry and expired/future codes are
excluded. Capabilities come from explicit server fields. Invalid data fails
closed; errors and object string representations do not include response bodies
or code values. Nothing is saved to disk.

On logout, backgrounding or account switch the UI must call `clear()`. Old
responses cannot restore state after this call or after a newer load starts.
The UI must consult `visibleCodes` with a current clock before display/copy.
Adapters must reject redirects, avoid caches and keep session material out of
logs. Browser cookie/CSRF handling and native secure storage/authentication are
still separate work. These constraints are not implemented by this interface.

Not yet covered: mutations, unassigned-code data, token reveal, enrollment,
real OAuth and platform lifecycle wiring. The existing fictional UI deliberately
remains separate until behavior and design parity are verified.

## Management mutation contract

`ManagementClient` covers owned entry creation, rename, account changes and deletion, source revocation, explicit code assignment and token revocation. It uses the current API request shapes. It does not mint tokens, enroll sources or create sharing grants.

The platform transport must supply session authentication and CSRF, reject redirects and use no-store responses. Never use an automation token as the session. No concrete network transport or UI binding ships here yet. The current UI remains fictional data.

No mutation retries automatically. Network failures, server errors and malformed success responses are reported as uncertain because the server might already have committed the write. Refresh/reconcile before offering a retry. Owner checks remain server-enforced.
