/* Extension sign-in core. Runs only in the extension's own background worker (trusted extension contexts).
 * Pages and content scripts never see the record, key, verifier or bearer. Every dependency is injected so
 * the same code is tested in node and in a real browser. See tool/extension/README.md.
 *
 * Storage layout:
 *  - records (extension-private IndexedDB): ONE record {deviceId, privateKey (non-extractable CryptoKey),
 *    publicKey (base64url raw P-256 point), created}. Written only after a successful exchange, in one put.
 *    Survives browser and worker restarts. Cleared on logout, invalid_grant (revoked/expired/generation) or
 *    a successful explicit re-sign-in (replaced). Never cleared by network errors, 429 or 5xx.
 *  - session (chrome.storage.session): PKCE verifier + state for the single pending flow, and the access bearer.
 *    Gone on browser restart; the record then renews without a new sign-in. */
const B64URL = /^[A-Za-z0-9_-]+$/;
const CODE = /^[A-Za-z0-9_-]{16,512}$/;
// Exactly the three GET routes the API lets an extension session read (device-read-http EXT_PATHS and
// entry-domains-http PATH). Everything else is answered locally as unsupported: no network, no renew, no state change.
export const READ_PATHS = Object.freeze(['/v1/manage/entries', '/v1/manage/active-codes', '/v1/manage/entry/domains']);
// The fourth GET, for the autofill worker only (the popup bridge keeps exactly the three above): one entry's generated code, exactly one
// `entry` query of the strict id shape. Nothing else may carry a query.
export const TOTP_READ = /^\/v1\/manage\/totp-code\?entry=[A-Za-z0-9_-]{1,128}$/;
const ACCESS_TTL_MS = 900000; // API contract: access lives 15 minutes from issue. Judged from OUR receipt time, never from the server's absolute value against our clock.
const MARGIN_MS = 30000;
const BACKOFF_MIN_MS = 10000, BACKOFF_MAX_MS = 60000; // The API allows 8 outstanding 60s nonces per device; at most 6 attempts a minute stays under it.
const PENDING_MS = 600000;
export const SIGN_IN_ERRORS = Object.freeze(['cancelled', 'invalid-return', 'unavailable', 'rejected', 'unsupported']);

export const b64url = bytes => {
  let s = '';
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
};
const random = c => b64url(c.getRandomValues(new Uint8Array(32)));
export async function pkceChallenge(verifier, c = globalThis.crypto) {
  return b64url(await c.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
}
/** Strict parse of the final identity-window URL. Returns the one code, or undefined. */
export function parseReturn(finalUrl, redirectUri, state) {
  if (typeof finalUrl !== 'string' || finalUrl.length > 4096 || !finalUrl.startsWith(redirectUri + '#')) return undefined;
  let u;
  try { u = new URL(finalUrl); } catch { return undefined; }
  if (u.origin + u.pathname !== redirectUri || u.search || u.username || u.password) return undefined;
  const seen = new Map();
  for (const kv of u.hash.slice(1).split('&')) {
    const i = kv.indexOf('=');
    if (i <= 0) return undefined;
    const k = kv.slice(0, i);
    if (seen.has(k)) return undefined;
    seen.set(k, kv.slice(i + 1));
  }
  if ([...seen.keys()].sort().join(',') !== 'code,state') return undefined;
  if (seen.get('state') !== state || !CODE.test(seen.get('code'))) return undefined;
  return seen.get('code');
}

export function createExtensionAuth({ api, webUrl, redirectKey, identity, fetch: doFetch, records, session, crypto: c = globalThis.crypto, now = Date.now }) {
  if (!/^https:\/\/[^/]+$/.test(api) || !/^[a-z]{3,12}$/.test(redirectKey)) throw new TypeError('Configured API origin and redirect key required');
  let generation = 0, renewing, active = 0;
  const opts = (extra = {}) => ({ credentials: 'omit', cache: 'no-store', redirect: 'error', ...extra });
  const post = async (path, body, headers = {}) => {
    let r;
    try {
      r = await doFetch(api + path, opts({ method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: body === undefined ? undefined : JSON.stringify(body) }));
    } catch { return { status: 0 }; }
    let json;
    try { const t = await r.text(); json = t.length > 8192 ? undefined : t ? JSON.parse(t) : undefined; } catch { json = undefined; }
    return { status: r.status, json };
  };
  const loadRecord = async () => {
    let r;
    try { r = await records.load(); } catch { return undefined; }
    // Partial record (key without id, id without key) is signed out.
    if (!r || typeof r.deviceId !== 'string' || !r.privateKey || typeof r.publicKey !== 'string') return undefined;
    return r;
  };
  const setAccess = async token => session.set('access', { token, receivedAt: now() });
  const freshAccess = a => a && typeof a.token === 'string' && Number.isSafeInteger(a.receivedAt) && now() >= a.receivedAt && now() - a.receivedAt < ACCESS_TTL_MS - MARGIN_MS;
  const validExchange = j => j && typeof j === 'object' && Object.keys(j).sort().join(',') === 'access,access_expires_at,device_id';

  async function signIn() {
    // A new sign-in cancels the previous pending flow (its window result is ignored).
    const mine = ++generation;
    await session.remove('pending');
    const verifier = random(c), state = random(c), challenge = await pkceChallenge(verifier, c);
    const redirectUri = identity.getRedirectURL();
    await session.set('pending', { verifier, state, created: now() });
    // The Pages bootstrap recognises the handoff by its leading extension=1.
    const url = webUrl + '#extension=1&' + new URLSearchParams({ challenge, redirect: redirectKey, state }).toString();
    let finalUrl;
    try {
      finalUrl = await identity.launchWebAuthFlow({ url, interactive: true });
    } catch {
      if (mine === generation) await session.remove('pending');
      return { ok: false, error: 'cancelled' };
    }
    if (mine !== generation) return { ok: false, error: 'cancelled' };
    const pending = await session.get('pending');
    await session.remove('pending');
    if (!pending || pending.state !== state || now() - pending.created > PENDING_MS) return { ok: false, error: 'cancelled' };
    const code = parseReturn(finalUrl, redirectUri, state);
    if (!code) return { ok: false, error: 'invalid-return' };
    // The key is made only now, non-extractable. It replaces the old record only after the exchange succeeds.
    const pair = await c.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    const publicKey = b64url(await c.subtle.exportKey('raw', pair.publicKey));
    const r = await post('/auth/extension/exchange', { code, redirect: redirectKey, renewal_key: publicKey, verifier });
    if (r.status === 401 || r.status === 400 || r.status === 403) return { ok: false, error: 'rejected' };
    if (r.status !== 200 || !r.json || !validExchange(r.json) || typeof r.json.device_id !== 'string' || typeof r.json.access !== 'string' || !Number.isSafeInteger(r.json.access_expires_at)) return { ok: false, error: 'unavailable' };
    if (mine !== generation) return { ok: false, error: 'cancelled' };
    const old = await loadRecord();
    await records.save({ deviceId: r.json.device_id, privateKey: pair.privateKey, publicKey, created: now() });
    await setAccess(r.json.access);
    await session.remove('backoff');
    // Best effort: do not leave the replaced device registered server-side (the API caps devices per owner).
    if (old && old.deviceId !== r.json.device_id) serverLogout(old).catch(() => {});
    return { ok: true };
  }

  const sign = async (rec, purpose, ch) => b64url(await c.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, rec.privateKey, new TextEncoder().encode(['otpanda-extension-v1', 'POST /auth/extension/' + purpose, rec.deviceId, ch.nonce, String(ch.expires_at)].join('\n'))));
  const dropRecord = async () => { await records.clear(); await session.remove('access'); await session.remove('backoff'); };
  const transient = () => Object.assign(Error('unavailable'), { transient: true });

  // The challenge route never reveals whether a device exists (it always answers 200), so a failure
  // at renew cannot be told apart from a nonce cap. Attempts are therefore spaced, shared across
  // reads and worker restarts through session storage, so retries cannot burn the nonce cap.
  async function renew() {
    const rec = await loadRecord();
    if (!rec) return undefined;
    const bo = await session.get('backoff');
    if (bo && Number.isSafeInteger(bo.until) && now() < bo.until) throw transient();
    const fail = async () => {
      const step = Math.min(BACKOFF_MAX_MS, Math.max(BACKOFF_MIN_MS, (bo?.step ?? BACKOFF_MIN_MS / 2) * 2));
      await session.set('backoff', { until: now() + step, step });
      throw transient();
    };
    const ch = await post('/auth/extension/challenge', { device_id: rec.deviceId, purpose: 'renew' });
    if (ch.status === 401) { await dropRecord(); return undefined; }
    if (ch.status !== 200 || !ch.json || typeof ch.json.nonce !== 'string') return fail();
    const r = await post('/auth/extension/renew', { device_id: rec.deviceId, expires_at: ch.json.expires_at, nonce: ch.json.nonce, signature: await sign(rec, 'renew', ch.json) });
    if (r.status === 401) { await dropRecord(); return undefined; }
    if (r.status !== 200 || !r.json || typeof r.json.access !== 'string' || !Number.isSafeInteger(r.json.access_expires_at)) return fail();
    await setAccess(r.json.access);
    await session.remove('backoff');
    return r.json.access;
  }

  /** Returns {token} | {state:'signed-out'} (record absent or just cleared) | {state:'unavailable'}. One renew in flight. */
  async function getAccess(force = false) {
    const a = await session.get('access');
    if (!force && freshAccess(a)) return { token: a.token };
    if (!(await loadRecord())) return { state: 'signed-out' };
    renewing ??= renew().finally(() => { renewing = undefined; });
    try {
      const token = await renewing;
      return token ? { token } : { state: 'signed-out' };
    } catch { return { state: 'unavailable' }; }
  }

  /** Keeps the bearer fresh for the popup. validMs counts from OUR receipt time, never from the server's clock. */
  async function maintain(force = false) {
    const t = await getAccess(force);
    if (!t.token) return { ok: false, signedOut: t.state === 'signed-out' };
    const a = await session.get('access');
    return { ok: true, validMs: freshAccess(a) ? ACCESS_TTL_MS - MARGIN_MS - (now() - a.receivedAt) : 0 };
  }

  async function status() {
    if (active > 0) return 'signing-in';
    return (await loadRecord()) ? 'signed-in' : 'signed-out';
  }

  /** {status, body, signedOut?}. signedOut is true only when the record is actually gone.
   * `read` is the POPUP-facing read (the message handler in background.js calls only this): the three READ_PATHS and nothing else.
   * `readInternal` adds the fourth GET (one generated code) for the autofill CodeSource inside the worker. It is never a message type. */
  const read = (path, retried = false) => doRead(path, retried, false);
  const readInternal = (path, retried = false) => doRead(path, retried, true);
  async function doRead(path, retried, internal) {
    if (!READ_PATHS.includes(path) && !(internal && typeof path === 'string' && TOTP_READ.test(path))) return { status: 503, body: '{}', unsupported: true };
    const t = await getAccess(retried);
    if (!t.token) return t.state === 'signed-out' ? { status: 401, body: '{}', signedOut: true } : { status: 503, body: '{}' };
    let r;
    try { r = await doFetch(api + path, opts({ method: 'GET', headers: { Authorization: 'Bearer ' + t.token } })); } catch { return { status: 503, body: '{}' }; }
    // A 401 gets one forced renew. The final 401 is never passed on as "signed out": only a cleared record is.
    if (r.status === 401) return retried ? { status: 503, body: '{}' } : doRead(path, true, internal);
    let body = '{}';
    try { body = await r.text(); if (body.length > 524288) return { status: 503, body: '{}' }; } catch { return { status: 503, body: '{}' }; }
    // A 429 hands its Retry-After (seconds) to the caller, which must not retry sooner.
    if (r.status === 429) { const ra = Number(r.headers?.get?.('retry-after')); return { status: 429, body, ...(Number.isSafeInteger(ra) && ra > 0 ? { retryAfter: Math.min(ra, 3600) } : {}) }; }
    return { status: r.status, body };
  }

  const TICKET = /^rt1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{43}$/;
  /** One-use realtime ticket for the popup's socket. Returns the ticket only, never the bearer. A 401 gets one
   * forced renew through the shared backoff; the final 401 never clears anything. */
  async function ticket(retried = false) {
    const t = await getAccess(retried);
    if (!t.token) return t.state === 'signed-out' ? { signedOut: true } : { unavailable: true };
    let r;
    try { r = await doFetch(api + '/auth/extension/realtime/ticket', opts({ method: 'POST', headers: { Authorization: 'Bearer ' + t.token } })); } catch { return { unavailable: true }; }
    if (r.status === 401) return retried ? { unavailable: true } : ticket(true);
    if (r.status !== 200) return { unavailable: true };
    let j;
    try { j = JSON.parse(await r.text()); } catch { return { unavailable: true }; }
    if (!j || typeof j.ticket !== 'string' || !TICKET.test(j.ticket) || !Number.isSafeInteger(j.closeAt) || !Number.isSafeInteger(j.serverTime)) return { unavailable: true };
    return { ticket: j.ticket, url: api.replace(/^https:/, 'wss:') + '/auth/extension/realtime', closeAfterMs: Math.max(0, j.closeAt - j.serverTime) };
  }

  async function serverLogout(rec) {
    const ch = await post('/auth/extension/challenge', { device_id: rec.deviceId, purpose: 'logout' });
    if (ch.status === 200 && ch.json && typeof ch.json.nonce === 'string') {
      await post('/auth/extension/logout', { device_id: rec.deviceId, expires_at: ch.json.expires_at, nonce: ch.json.nonce, signature: await sign(rec, 'logout', ch.json) });
    }
  }

  /** Server logout first (signed). Its failure never blocks local cleanup. */
  async function logout() {
    generation++;
    const rec = await loadRecord();
    try { if (rec) await serverLogout(rec); } catch { /* local cleanup still runs */ }
    try { await records.clear(); } finally {
      await session.remove('access'); await session.remove('pending'); await session.remove('backoff');
    }
  }

  /** Worker start: a pending flow cannot survive a worker restart (its window promise is gone). */
  async function recover() { await session.remove('pending'); }

  return Object.freeze({ signIn: async () => { active++; try { return await signIn(); } finally { active--; } }, read, maintain, ticket, logout, status, recover, getAccess, readInternal });
}

/** IndexedDB record store: extension-private origin, non-extractable CryptoKey stored by structured clone. */
export function idbRecords(indexedDB, name = 'otpanda-extension-v1') {
  const open = () => new Promise((res, rej) => {
    const q = indexedDB.open(name, 1);
    q.onupgradeneeded = () => q.result.createObjectStore('record');
    q.onsuccess = () => res(q.result);
    q.onerror = () => rej(q.error);
  });
  const run = async (mode, fn) => {
    const db = await open();
    try {
      return await new Promise((res, rej) => {
        const tx = db.transaction('record', mode), req = fn(tx.objectStore('record'));
        tx.oncomplete = () => res(req?.result);
        tx.onerror = tx.onabort = () => rej(tx.error);
      });
    } finally { db.close(); }
  };
  return Object.freeze({
    load: () => run('readonly', s => s.get('device')),
    save: rec => run('readwrite', s => s.put({ deviceId: rec.deviceId, privateKey: rec.privateKey, publicKey: rec.publicKey, created: rec.created }, 'device')),
    clear: () => run('readwrite', s => s.delete('device')),
  });
}
