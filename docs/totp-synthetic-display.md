# Synthetic generated-code display

The fictional local catalog exposes an explicit "Preview fictional generated code" button on explicitly opted-in sample cards. It opens a dismissible, scrollable dialog identifying the selected fictional entry. Each opening creates a fresh in-process store and continuing Stopwatch; closing disposes the panel and clears the store. The connected account page does not import or expose this dialog. The preview is included in normal fictional app builds but is not connected to an account or service. Its private in-process transport returns the fixed fictional value `001234`, with a ten-second conservative display lifetime after each explicit load. It does not fetch, persist, copy, provision seeds, or automatically refresh codes.

The panel clears its dedicated store on initialization, every lifecycle notification (including resume), selected-entry changes, scope changes, store replacement and disposal. A caller must change `scopeKey` for account, session, catalog or permission changes. Background states disable loading. Returning to the panel requires an explicit fresh load. Stale load completions and stale errors cannot restore the display or affect the current scope. The UI retains no code field of its own and checks store visibility during each build. A foreground timer repaints every 100ms; event-loop suspension can delay painting, so this is not an exact wall-clock display guarantee.

The store remains memory-only, without guaranteed string erasure. Widget lifecycle tests simulate notifications, not real OS sleep, browser background throttling or native lifecycle delivery. Actual web visibility/focus lifecycle delivery is untested. This panel is not a production safety boundary. The existing generated-code contract's real transport freshness, continuing monotonic-clock, server-clock and invalidation requirements still apply before any live display or copy action. Production authentication and supported encryption-key custody remain blocked; the live route stays unmounted. Durable-device work is unchanged.

`tool/totp_preview.dart` also remains a separate local target using the same panel. Local preview, after generating a disposable Flutter web host if needed:

```
flutter run -d chrome --target tool/totp_preview.dart
```

Tests cover explicit loading, leading zeros, monotonic expiry without refetch, every nonresumed lifecycle state, resume without reload, pending loads invalidated by background/entry/scope/store/disposal changes, generic errors and stale failure suppression through store cancellation (not independent proof of the panel error-generation guard), and 320px/1280px layouts. Screenshots of the separate release target verify mobile active/expired states and a wide active state. Browser screenshots do not establish native sleep behavior or real transport freshness.

ClientHome defaults fictionalCatalog to false. Only the hardcoded fictional OTPandaApp opts in; the button and handler both require that explicit flag, never manage permission. Both owned and shared samples can preview fictional data. This is not the real sharing policy: active share recipients may read live generated codes under the separate API permissions. Never opt a real catalog into this fixture mode. The normal fictional build also ships in the optional extension preview.

The catalog wrapper accepts only identity labels from the local fictional catalog; it has no transport injection, bridge, network client, credentials or seed. The fixed code is a demonstration, not derived from the entry and not evidence of authenticator enrollment. Existing received-code clipboard behavior is separate; the generated-code dialog has no copy action. Tests observe route dismissal and an empty reopened view. Store isolation follows from State-owned construction and disposal, not from those UI assertions alone. The platform-pop test calls the binding platform-route handler; it is not evidence from a physical back button.

The dialog title supplies header and route-name semantics. Keyboard focus and screen-reader behavior remain untested; semantics metadata is not proof of accessibility.
