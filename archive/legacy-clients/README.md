# Retired client histories

The unified client repository is otpanda/app, including its Flutter browser-extension popup and platform integration boundary. The web and extension git bundles contain every fetched branch and pull-request head from the old repositories, verified as complete before retirement on 2026-11-25. The issue JSON files preserve the old issue and pull-request listings, including the remaining readiness notes. Git bundles can be inspected or restored with git clone; they are not active clients or deployment inputs.

Retained repositories: app (unified client), api (service), home (landing page), otpanda.github.io (app-link and passkey domain association infrastructure).

Legacy web Pages used https://otpanda.github.io/web/ with no custom domain. The canonical active client is https://otpanda.github.io/app/.

Autofill helper code lives under tool/extension/autofill, alongside the shared Flutter extension packager. Its synthetic tests do not establish live browser integration. No new browser permissions or authentication activation are included in this consolidation.
