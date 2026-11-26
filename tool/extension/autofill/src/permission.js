// Popup-side, CLASSIC script (loaded by a <script> tag; defines globalThis.OTPandaAutofill). Nothing runs at load: no request, no read.
// The optional HTTPS host grant is requested ONLY when the Flutter popup calls request() from a user's click/tap (transient user activation is
// required and checked). The origins come from the worker (listed domains + the user's own associations, exact hosts, https only). Never automatic.
(() => {
 'use strict';
 const ORIGIN = /^https:\/\/(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\/\*$/;
 const MAX = 500;
 async function origins() {
  const r = await chrome.runtime.sendMessage({ type: 'autofillOrigins' });
  const list = r && r.ok && r.value && Array.isArray(r.value.origins) ? r.value.origins : [];
  return [...new Set(list.filter(o => typeof o === 'string' && ORIGIN.test(o)))].sort().slice(0, MAX);
 }
 // Plain wording for the popup (primary/Dart renders it): what the grant does, that it is automatic once granted, and that it is revocable.
 const copy = Object.freeze({
  title: 'Autofill codes on your sites',
  body: 'After you allow this, OTPanda fills your one-time code automatically, only when the page is open and in front, the code field is empty, and the site is a 2FA Directory listed site or one of your own saved sites. It never fills a password or overwrites what is typed. Your browser asks you first, and you can turn this off at any time.',
  allow: 'Allow autofill', revoke: 'Turn off autofill',
 });
 // The browser requires the grant request to run inside the user's gesture (transient activation, about 5s). The worker round trip (entries reads,
 // first-run catalogue fetch) can exceed that, so origins are fetched AHEAD by prepare()/status() (no gesture needed; call when the settings row
 // appears and again when it is shown after a while) and request() calls chrome.permissions.request SYNCHRONOUSLY from the tap with the prepared
 // list: nothing is awaited between the tap and the browser call. An empty or stale (> FRESH_MS) list returns 'refresh' instead of guessing.
 const FRESH_MS = 60_000;
 let prepared = [], total = 0, at = -Infinity, failed = false;
 const info = () => ({ total, requested: prepared.length, truncated: total > prepared.length });
 const api = {
  copy,
  // -> {status:'ready'|'none'|'error', total (all valid candidates), requested (<= MAX, what the prompt will list), truncated}. No prompt, no gesture.
  async prepare() {
   try {
    const r = await chrome.runtime.sendMessage({ type: 'autofillOrigins' });
    if (!(r && r.ok && r.value && Array.isArray(r.value.origins))) throw new Error('origins');
    const all = [...new Set(r.value.origins.filter(o => typeof o === 'string' && ORIGIN.test(o)))].sort();
    total = all.length; prepared = all.slice(0, MAX); at = Date.now(); failed = false;
    return { status: total ? 'ready' : 'none', ...info() };
   } catch { prepared = []; total = 0; at = -Infinity; failed = true; return { status: 'error', ...info() }; }
  },
  // Stable contract for the popup row: {status:'ready'|'none'|'error', total, requested, truncated, granted:boolean (every requested origin granted),
  // grantedCount (how many of the requested origins are granted now), error?:true}. Read-only, never prompts.
  async status() {
   const p = await api.prepare(); if (p.status === 'error') return { ...p, granted: false, grantedCount: 0, error: true };
   if (p.status === 'none') return { ...p, granted: false, grantedCount: 0 };
   try {
    const have = new Set(((await chrome.permissions.getAll()).origins || []));
    const n = prepared.filter(o => have.has(o)).length;
    return { ...p, granted: n === prepared.length, grantedCount: n };
   } catch { return { ...p, status: 'error', granted: false, grantedCount: 0, error: true }; }
  },
  // Call synchronously from a click/tap handler, after prepare()/status().
  // -> 'granted' | 'declined' (user said no) | 'error' (browser refused or failed) | 'needs-gesture' | 'refresh' (call prepare() again) | 'none' (no candidates).
  request() {
   if (!(globalThis.navigator && navigator.userActivation && navigator.userActivation.isActive)) return Promise.resolve('needs-gesture');
   if (failed || Date.now() - at > FRESH_MS) return Promise.resolve('refresh');
   if (!prepared.length) return Promise.resolve('none');
   return chrome.permissions.request({ origins: prepared }).then(ok => (ok ? 'granted' : 'declined'), () => 'error');
  },
  // Removes every granted optional https origin (never the manifest's required host permissions, i.e. the API). The worker sees permissions.onRemoved
  // and unregisters the content script. -> 'removed' | 'none' | 'error'
  async revoke() {
   try {
    const required = chrome.runtime.getManifest().host_permissions || [];
    const have = ((await chrome.permissions.getAll()).origins || []).filter(o => typeof o === 'string' && o.startsWith('https://') && !required.includes(o));
    if (!have.length) return 'none';
    return (await chrome.permissions.remove({ origins: have })) ? 'removed' : 'error';
   } catch { return 'error'; }
  },
 };
 Object.defineProperty(globalThis, 'OTPandaAutofill', { value: Object.freeze(api), writable: false, configurable: false });
})();
