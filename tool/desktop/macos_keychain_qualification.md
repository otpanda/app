# macOS wrapping-key store: backend choice, constraints, qualification plan

## Real-host result (primary, CI run 46001583630 job 140514293630) and response

Same-binary read, duplicate create and six-process race passed. Rebuilt binaries (plain ad-hoc and explicit DR) HUNG on existing-key read and duplicate create
until the 20 s alarm. Two consequences:
1. kSecUseAuthenticationUI=Fail does NOT suppress the legacy file-based ACL prompt (a hang, not an errSecInteractionNotAllowed). The adapter now wraps each
   SecItem call in SecKeychainSetUserInteractionAllowed(false) (scoped, locked, restored). Unproven until the probe shows a refusal status quickly instead of a TIMEOUT.
2. The probe changed the binary at the same path, but the first run rebuilt to different bytes only; primary notes path vs identity was not separated. The probe
   now runs, per signing mode (plain ad-hoc, explicit DR, local self-signed identity with DR `identifier + certificate leaf hash`): a COPY of the same signed binary at
   another path, a REBUILT binary at another path, and a REBUILT binary at the SAME path. Each row is a bounded read and duplicate create with elapsed time, with the
   item's ACL entries dumped (no secret data). No scenario widens the ACL to all applications. A refused attempt must leave the item present.

Hypotheses the data will confirm or kill (none is established): the ACL trusted-app entry for an ad-hoc binary keys on cdhash or path, and since macOS 10.12 a separate
partition list (cdhash: for ad-hoc and self-signed binaries, teamid: only with an Apple team) may refuse a rebuilt binary even when the ACL entry matches. If so, a stable
free identity cannot be had on the file-based keychain, and the data-protection keychain needs a profile (not free in CI). The remaining safe design is then: updates keep
the key only when the new build is allowed; otherwise a typed `denied`/`locked` state and a user recovery path, never reset, overwrite or ACL widening.

Status: source only. Nothing here has been compiled or run. No Swift toolchain,
Xcode, Mac or Apple Developer account was available when it was written. No
paid membership is needed for the default backend.

## Backend (compile-time, never a runtime fallback)

`macos_overlay.py` inlines the Swift into MainFlutterWindow.swift and sets one
constant, `SystemKeychainOps.backend`:

- `file` (default): the user's login keychain through SecItem. Generic-password
  item, service `app.otpanda.wrapping-key`, account = install namespace, 32
  opaque bytes. No entitlement, no provisioning profile.
- `data-protection` (`--backend=data-protection`): Data Protection keychain,
  non-synchronizable, WhenUnlockedThisDeviceOnly. Also adds
  keychain-access-groups. Needs a signed build with a provisioning profile.

An item in one store is invisible to the other. Switching backends after real
data exists looks like an absent key, so it is a build decision, not a runtime
one. The caller's sealed canary stays required.

## What Apple documents (sources fetched)

- TN3137 (https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains.md):
  the file-based keychain uses ACLs (SecAccess); the data protection keychain uses
  access groups from code-signing entitlements, which "must be authorized by a
  provisioning profile". The file-based keychain is "on the road to
  deprecation" but not officially deprecated, and SecItem against it goes through
  a shim with known limitations. macOS 26.4 and later: a keychain file may
  depend on a separate protected entropy file when backed up or moved.
- TN2206 (https://developer.apple.com/library/archive/technotes/tn2206/_index.html):
  for keychain access controls, "the creating application is automatically
  trusted with its item" and tracked by its designated requirement (DR). Code
  signing identity is judged per subsystem; the keychain does not need a trusted
  anchor.
- Access Control Lists (Apple docs mirror, https://apple-docs.everest.mt/docs/security/access-control-lists/):
  if the caller is not a trusted app for the item, the system prompts the user
  (Deny, Allow, Always Allow). Always Allow adds the app to the item's ACL.
- SecAccessCreate: passing NULL for the trusted list sets the ACL to the
  creating application only.

Not found in Apple text, only in third-party reports: an ad-hoc signature's DR
is the code hash (cdhash), so every rebuild is a new identity. Several issue
threads describe the consequence: after the binary changes, access prompts
return or fail. That is exactly what `macos_keychain_probe.sh` measures.

## Consequences for the file-based default

1. Access is tied to the creating app's DR. For ad-hoc builds that is the
   cdhash. After an update, the old item is not trusted by the new binary. With
   system UI disabled (below) that reads as a refusal, never as a prompt and
   never as absence. Never recreate on refusal: that would orphan sealed state.
2. Calls set kSecUseAuthenticationUI to Fail so a hidden ACL or unlock dialog
   cannot hang the app. The status then is -25308 for both "keychain locked" and
   "app not in ACL". The core separates them: if the login keychain reports
   unlocked, it is `denied` (ACL); otherwise `locked`; unknown stays `locked`.
   kSecUseAuthenticationUI is a deprecated constant, and
   SecKeychainGetStatus is deprecated too. Both still need real-host proof.
3. Encryption at rest: the login keychain is encrypted under the user's login
   secret (Apple Platform Security). Items are not hardware-bound and are
   readable by any process the ACL trusts, and by the user via Keychain Access.
4. Create-only: SecItemAdd on a duplicate service+account returns
   errSecDuplicateItem in the target keychain (errSecDuplicateItem is documented
   as "the item already exists"). The adapter treats that as "re-read the
   winner", never overwrites, and never uses SecItemUpdate. Whether two
   processes racing a first add always produce exactly one winner is measured by
   the probe, not assumed.
5. Not synchronized to iCloud, and it moves with the login keychain file (see the
   macOS 26.4 note above). A restore to another Mac yields an absent key beside
   existing sealed state, which must surface as a recovery state, not a reset.
6. One open third-party report (flutter_secure_storage #1104) shows -34018 on
   macOS 26.4 even for a non-entitled file-based call. -34018 maps to `denied`.
   The probe will show whether the host used here is affected.
7. A stable identity would make upgrades keep access. Options that cost nothing
   are an explicit DR (`codesign -r='designated => identifier "..."'`), which is
   spoofable by any binary that claims the same identifier, or a local
   self-signed code-signing certificate. Neither is documented as safe here;
   the probe's `dr` scenario measures the first. Do not adopt either without
   that result.

## Status mapping

| Keychain status | Read | Create / delete |
| --- | --- | --- |
| success, 32 bytes | key | created (verified by read-back) / deleted |
| success, other size or no data | corrupt | corrupt on duplicate; never overwritten |
| errSecItemNotFound (-25300) | absent (null) | delete succeeds |
| errSecDuplicateItem (-25299) | n/a | winner re-read, returned, created=false |
| -25308 / -25315, keychain locked or lock state unknown | locked | locked, known not applied |
| -25308 / -25315, keychain unlocked (ACL refusal) | denied | denied, known not applied |
| errSecAuthFailed, errSecUserCanceled, -34018 | denied | denied, known not applied |
| errSecParam | unavailable | unavailable, known not applied |
| anything else | unavailable (never absent) | unavailable, outcomeUnknown; create reads back first and reports absent as known not applied |

## Real-host qualification plan

Run on a free GitHub macOS runner or any Mac with Swift. Nothing needs a team.

1. `swiftc -parse-as-library WrappingKeyCore.swift WrappingKeyCoreTests.swift -o t && ./t`
   (fakes, no Keychain). Expect ALL PASSED.
2. `python tool/desktop/macos_overlay_test.py`, `flutter test
   test/macos_wrapping_key_store_test.dart`, `flutter analyze`.
3. `bash tool/desktop/macos_keychain_probe.sh`: real ad-hoc binaries, lifecycle,
   duplicate create, six-process race, rebuild (new cdhash) with and without an
   explicit DR, cleanup. Contract failures exit 1. The "DATA" lines answer the
   ad-hoc upgrade question and must be recorded, not assumed.
4. In the built app on an interactive Mac: first launch creates the key; quit and
   relaunch reads it; lock the screen or run `security lock-keychain` and expect
   `locked`, no dialog, no hang; unlock and retry.
5. Update test: install build N, create key, replace with build N+1 (new
   cdhash). Record read result: success, denied or a prompt. If denied, the
   product needs a documented recovery path (restore from the user's own
   backup), not silent reset.
6. Corrupt: `security add-generic-password -s app.otpanda.wrapping-key -a <ns>
   -w short` then read and create: expect `corrupt`, item unchanged.
7. Confirm no log line, crash report or Console entry contains key bytes.
