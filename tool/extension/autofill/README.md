# Extension autofill modules (inert)

Auth-independent pieces for browser-extension code autofill, kept in this app repo. Nothing here is packaged or wired: `tool/extension/package.mjs` does not include it, the manifest requests no host permission, and there is no sign-in or API call. Synthetic fake-DOM tests only; not run in a real browser.

- `match.js`: exact normalized HTTPS host equality between a page and an entry's domains (2FAD domains plus the user's own associations, supplied by the caller). No parent, subdomain, wildcard, IP, port or userinfo matching.
- `fill-request.js`: page host comes only from the browser-provided sender URL. Releases a code only when exactly one eligible entry has a fresh, unexpired, well-formed code. Eligibility is not a code-release grant by itself.
- `fields.js`, `content.js`: one-time-code field detection and fill.
- `background.js`: service-worker glue; registers the content script only for exact hosts and only if the optional host permission was already granted. Needs a CodeSource from the future login work.

Run: `node --test tool/tool/extension/autofill/test`
