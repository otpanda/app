/* Pages side of the native sign-in handoff. Classic script, loaded before session-bootstrap.js.
 * The Android client opens https://otpanda.github.io/app/#native=1&challenge=C&state=S[&provider=google[&remember=0|1]].
 * This parses that fragment strictly. It never accepts a redirect, return URL or any extra field:
 * the API owns the fixed app-return destination. Pure functions, no storage, no navigation. */
(() => {
  'use strict';
  const OPAQUE = /^[A-Za-z0-9_-]{43}$/;
  const API = 'https://otpanda-api.abrahammurciano.workers.dev';
  const NATIVE_REDIRECT = API + '/app-return';
  function parseNativeIntent(hash) {
    if (typeof hash !== 'string' || hash[0] !== '#') return null;
    const seen = new Map();
    for (const kv of hash.slice(1).split('&')) {
      const i = kv.indexOf('=');
      if (i <= 0) return null;
      const k = kv.slice(0, i), v = kv.slice(i + 1);
      if (seen.has(k)) return null;
      seen.set(k, v);
    }
    const keys = [...seen.keys()].sort().join(',');
    if (!['challenge,native,state', 'challenge,native,provider,state', 'challenge,native,provider,remember,state'].includes(keys)) return null;
    if (seen.get('native') !== '1') return null;
    const challenge = seen.get('challenge'), state = seen.get('state');
    if (!OPAQUE.test(challenge) || !OPAQUE.test(state)) return null;
    if (seen.has('provider')) {
      // Allowlist: the only provider is Google, chosen by the native app when it has no Google services.
      if (seen.get('provider') !== 'google') return null;
      // remember is the user's own checkbox choice, carried through. Absent means the web default (yes).
      if (seen.has('remember')) {
        const r = seen.get('remember');
        if (r !== '0' && r !== '1') return null;
        return { challenge, state, provider: 'google', remember: r === '1' };
      }
      return { challenge, state, provider: 'google' };
    }
    return { challenge, state };
  }
  // The API-hosted, intent-bound approve page (GET shows an explicit Continue; the POST rotates the
  // first-party web cookie and 303s to /app-return#code&state). It takes exactly challenge, state and
  // the fixed redirect_uri; the API refuses anything else.
  function nativeApproveUrl(intent) {
    const u = new URL(API + '/auth/native/approve');
    u.search = new URLSearchParams({
      challenge: intent.challenge, state: intent.state, redirect_uri: NATIVE_REDIRECT,
    });
    return u.href;
  }
  const api = Object.freeze({ parseNativeIntent, nativeApproveUrl, NATIVE_REDIRECT });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else Object.defineProperty(globalThis, 'OTPandaNativeIntent', { value: api });
})();
