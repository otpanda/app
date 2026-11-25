// Pages side of the native sign-in handoff (not wired into index.html; primary owns that hunk).
// The Android client opens https://otpanda.github.io/app/#native=1&challenge=C&state=S.
// This parses that fragment strictly. It never accepts a redirect, return URL or
// any extra field: the API owns the fixed app-return destination.
'use strict';
const OPAQUE = /^[A-Za-z0-9_-]{43}$/;
const API = 'https://otpanda-api.abrahammurciano.workers.dev';
function parseNativeIntent(hash) {
  if (typeof hash !== 'string' || hash[0] !== '#') return null;
  const parts = hash.slice(1).split('&');
  const seen = new Map();
  for (const kv of parts) {
    const i = kv.indexOf('=');
    if (i <= 0) return null;
    const k = kv.slice(0, i), v = kv.slice(i + 1);
    if (seen.has(k)) return null;
    seen.set(k, v);
  }
  if ([...seen.keys()].sort().join(',') !== 'challenge,native,state') return null;
  if (seen.get('native') !== '1') return null;
  const challenge = seen.get('challenge'), state = seen.get('state');
  if (!OPAQUE.test(challenge) || !OPAQUE.test(state)) return null;
  return { challenge, state };
}
// The API-hosted, intent-bound approve page (GET shows an explicit Continue; the POST
// rotates the first-party web cookie and 303s to /app-return#code&state). It takes
// exactly challenge, state and the fixed redirect_uri; the API refuses anything else.
const NATIVE_REDIRECT = API + '/app-return';
function nativeApproveUrl(intent) {
  const u = new URL(API + '/auth/native/approve');
  u.search = new URLSearchParams({
    challenge: intent.challenge, state: intent.state, redirect_uri: NATIVE_REDIRECT,
  });
  return u.href;
}
if (typeof module !== 'undefined') module.exports = { parseNativeIntent, nativeApproveUrl, NATIVE_REDIRECT };
