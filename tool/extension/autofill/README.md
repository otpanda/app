# Extension autofill

Packaged only when extension sign-in is explicitly enabled. The default fictional preview has no sign-in or website permissions. Production extension access remains separately gated by the API.

- Exact catalogue primary `catalogId` lookup supplies listed primary and additional domains, unioned with the viewer's own associations. Names, issuers and logos never determine a match.
- Optional HTTPS access is requested from the popup's Allow action for prepared exact candidate hosts only. Chrome asks before adding access. Scripts register only for granted candidate hosts.
- Only a visible, focused document with an empty, rendered OTP field can receive a code. No passwords, overwrites, cross-origin ancestor frames or ungranted subdomains. Eligibility is rechecked after awaits.
- The worker loads fresh entries, checks exact browser-provided sender host and releases only one unambiguous, unexpired code. Received codes are preferred; matched-entry TOTP reads stay worker-only.
- The public catalogue cache has a seven-day TTL and a 2 MiB response limit. Missing candidate data fails closed rather than accepting a partial set.
- Signing out unregisters scripts and blocks reads while retaining optional grants. Turn off autofill removes optional grants without removing the required API permission.
- Content requests are coalesced and throttled. Popup code updates use its existing realtime transport, not snapshot polling.

Run `node --test tool/extension/autofill/test/*.test.js tool/extension/*.test.mjs`. Set `OTPANDA_API_SRC` to the API checkout to include its negative route audit. Synthetic tests do not prove provider sign-in or production activation.
