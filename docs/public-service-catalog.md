# Public service catalogue and logos

The authenticated ProductShell Add authenticator flow offers a searchable service picker. Search stays local. Picking a service sets a suggested name and a separate, owner-asserted catalogId. Editing the name retains the picked identity; removing the selection drops it. Custom names without a selection remain supported. Multiple entries for a service remain supported.

Both TOTP enrollment requests carry the optional catalogId. The API binds it into the passkey action and stores it only on the new entry. It does not change service_id, global services, sender rules, assignment or authorization. Readers, including authorized recipients, can use the value for display and exact catalogue lookup. It is not proof of service ownership or sender identity. API migration 0049 and its implementation must be deployed before this client can send the new field.

## Runtime fetch and cache

Clients fetch the public catalogue directly from https://api.2fa.directory/v3/all.json and logos from the upstream repository. They cache validated responses locally and fall back to cached data or the bundled snapshot. Typing does not send search queries upstream. No account name, email, phone number, secret or source connection is transmitted to the directory. A logo request exposes the selected public logo filename to its upstream host.

Web uses local storage; native uses the application cache directory. Network failures must leave usable cached data intact. Cache data is untrusted and bounded. See the directory implementation and its tests for precise validation and size limits. Build-time snapshot refresh remains a fallback rather than a server-side mirror. Attribution and the upstream licence are bundled with the snapshot. Upstream authenticity is not established by a stored digest.

## Domain rules and delivery scope

The approved autofill rule is the exact union of the selected catalogue service's listed domains and the current viewer's private associations. No inferred subdomains, service-name matching or sender grants are authorized by that rule. This catalogue/picker change does not itself implement the extension's autofill union or grant browser site permissions. Those remain separate delivery work. No mailbox connection or generated-code access is enabled by selecting a service.

## Verification

Host tests cover catalogue validation, cache fallback, logo identity, the real ProductShell enrollment picker, optional enrollment fields, additive read compatibility and the display-only consumer allowlist. Native cache qualification must use the real path_provider plugin on Android, not a host fake. Browser acceptance must exercise a compiled client with the actual API enrollment handlers and D1. Report the exact completed checks and remaining gaps rather than treating this document as acceptance evidence.
