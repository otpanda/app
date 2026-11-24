# Synthetic generated-code display

`tool/totp_preview.dart` is a separate local target. It is not imported by the normal app, built by Pages/extension workflows, or connected to an account or service. Its in-process transport returns the fixed fictional value `001234`, with a ten-second conservative display lifetime after each explicit load. It does not fetch, persist, copy, provision seeds, or automatically refresh codes.

The panel clears its dedicated store on initialization, every lifecycle notification (including resume), selected-entry changes, scope changes, store replacement and disposal. A caller must change `scopeKey` for account, session, catalog or permission changes. Background states disable loading. Returning to the panel requires an explicit fresh load. Stale load completions and stale errors cannot restore the display or affect the current scope. The UI retains no code field of its own and checks store visibility during each build. A foreground timer repaints every 100ms; event-loop suspension can delay painting, so this is not an exact wall-clock display guarantee.

The store remains memory-only, without guaranteed string erasure. Widget lifecycle tests simulate notifications, not real OS sleep, browser background throttling or native lifecycle delivery. Actual web visibility/focus lifecycle delivery is untested. This panel is not a production safety boundary. The existing generated-code contract's real transport freshness, continuing monotonic-clock, server-clock and invalidation requirements still apply before any live display or copy action. Production authentication and supported encryption-key custody remain blocked; the live route stays unmounted. Durable-device work is unchanged.

Local preview, after generating a disposable Flutter web host if needed:

```
flutter run -d chrome --target tool/totp_preview.dart
```

Tests cover explicit loading, leading zeros, monotonic expiry without refetch, every nonresumed lifecycle state, resume without reload, pending loads invalidated by background/entry/scope/store/disposal changes, generic errors and stale failure suppression through store cancellation (not independent proof of the panel error-generation guard), and 320px/1280px layouts. Screenshots of the separate release target verify mobile active/expired states and a wide active state. Browser screenshots do not establish native sleep behavior or real transport freshness.
