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
