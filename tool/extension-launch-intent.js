/* Pages side of the browser-extension sign-in handoff. Classic script, loaded before session-bootstrap.js.
 * The extension opens https://otpanda.github.io/app/#extension=1&challenge=C&redirect=KEY&state=S.
 * KEY names a redirect the API already allowlists ('chrome' or 'firefox'); it is never a URL.
 * Pure functions: no storage, no navigation, no network. */
(() => {
  'use strict';
  const OPAQUE = /^[A-Za-z0-9_-]{43}$/;
  const KEYS = ['chrome', 'firefox'];
  function parseExtensionIntent(hash) {
    if (typeof hash !== 'string' || hash[0] !== '#' || hash.length > 512) return null;
    const seen = new Map();
    for (const kv of hash.slice(1).split('&')) {
      const i = kv.indexOf('=');
      if (i <= 0) return null;
      const k = kv.slice(0, i), v = kv.slice(i + 1);
      if (seen.has(k)) return null;
      seen.set(k, v);
    }
    if ([...seen.keys()].sort().join(',') !== 'challenge,extension,redirect,state') return null;
    if (seen.get('extension') !== '1') return null;
    const challenge = seen.get('challenge'), state = seen.get('state'), redirect = seen.get('redirect');
    if (!OPAQUE.test(challenge) || !OPAQUE.test(state) || !KEYS.includes(redirect)) return null;
    return { challenge, state, redirect };
  }
  // Defence in depth for the URL the API returns: the extension's own https root, a one-use code and the
  // exact state in the fragment only. Firefox stays refused until its real redirect host is verified.
  const HOSTS = { chrome: /^[a-p]{32}\.chromiumapp\.org$/ };
  function validReturn(redirect, state, key) {
    if (typeof redirect !== 'string' || redirect.length > 2048 || !HOSTS[key]) return null;
    let u;
    try { u = new URL(redirect); } catch { return null; }
    if (u.protocol !== 'https:' || u.port || u.username || u.password || u.search || u.pathname !== '/' || !HOSTS[key].test(u.hostname)) return null;
    const p = new URLSearchParams(u.hash.slice(1));
    if ([...p.keys()].sort().join(',') !== 'code,state' || p.get('state') !== state || !/^[A-Za-z0-9_-]{16,512}$/.test(p.get('code'))) return null;
    return u.href;
  }
  const api = Object.freeze({ parseExtensionIntent, validReturn, KEYS });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else Object.defineProperty(globalThis, 'OTPandaExtensionIntent', { value: api });
})();
