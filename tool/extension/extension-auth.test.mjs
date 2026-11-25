import test from 'node:test';
import assert from 'node:assert/strict';
import { createExtensionAuth, parseReturn, pkceChallenge, b64url } from './extension-auth.mjs';

const API = 'https://api.example', WEB = 'https://pages.example/app/', RU = 'https://abc.chromiumapp.org/';
const mem = () => { const m = new Map(); return { get: async k => m.get(k), set: async (k, v) => { m.set(k, v); }, remove: async k => { m.delete(k); }, m }; };
const recs = () => { let r; return { load: async () => r, save: async x => { r = x; }, clear: async () => { r = undefined; }, peek: () => r, put: x => { r = x; } }; };
const mk = (over = {}) => {
  const session = mem(), records = recs(), calls = [];
  let t = 1e12; const now = () => t;
  const net = over.net ?? (async () => ({ status: 500, text: async () => '' }));
  const auth = createExtensionAuth({ api: API, webUrl: WEB, redirectKey: 'chrome', identity: over.identity ?? { getRedirectURL: () => RU, launchWebAuthFlow: async () => { throw Error('x'); } }, fetch: async (u, o) => { calls.push({ u, o }); return net(u, o); }, records, session, now });
  return { auth, session, records, calls, tick: ms => { t += ms; } };
};
const R = (status, json) => ({ status, text: async () => (json === undefined ? '' : JSON.stringify(json)) });
const goodIdentity = (grab) => ({ getRedirectURL: () => RU, launchWebAuthFlow: async ({ url }) => { const p = new URLSearchParams(url.slice(url.indexOf('#') + 1)); grab?.(p, url); return RU + '#code=' + 'c'.repeat(43) + '&state=' + p.get('state'); } });

test('parseReturn: exact URI, fragment only, exactly code and state, matching state', () => {
  const s = 's'.repeat(43), c = 'c'.repeat(43);
  assert.equal(parseReturn(`${RU}#code=${c}&state=${s}`, RU, s), c);
  for (const u of [`${RU}?a=1#code=${c}&state=${s}`, `${RU}#code=${c}&state=${s}&x=1`, `${RU}#code=${c}`, `${RU}#code=${c}&state=${'z'.repeat(43)}`, `${RU}#code=${c}&code=${c}&state=${s}`, `https://evil.example/#code=${c}&state=${s}`, `${RU}x#code=${c}&state=${s}`, `${RU}#code=short&state=${s}`, undefined]) assert.equal(parseReturn(u, RU, s), undefined, String(u));
});
test('refuses to build without a configured https API origin and redirect key', () => {
  assert.throws(() => createExtensionAuth({ api: 'http://x', webUrl: WEB, redirectKey: 'chrome' }), TypeError);
  assert.throws(() => createExtensionAuth({ api: API, webUrl: WEB, redirectKey: 'https://x/' }), TypeError);
});
test('sign-in sends exact exchange keys with PKCE S256 and a 65-byte public key; record saved only after success', async () => {
  let grabbed, body;
  const t = mk({ identity: goodIdentity((p, url) => { grabbed = { p, url }; }), net: async (u, o) => { body = JSON.parse(o.body); return R(200, { device_id: 'dev_1', access: 'tok', access_expires_at: 1e12 + 300000 }); } });
  assert.deepEqual(await t.auth.signIn(), { ok: true });
  assert.ok(grabbed.url.startsWith(WEB + '#extension=1&'));
  assert.deepEqual([...grabbed.p.keys()].sort(), ['challenge', 'extension', 'redirect', 'state']);
  assert.equal(grabbed.p.get('redirect'), 'chrome');
  assert.deepEqual(Object.keys(body).sort(), ['code', 'redirect', 'renewal_key', 'verifier']);
  assert.equal(body.redirect, 'chrome');
  assert.equal(await pkceChallenge(body.verifier), grabbed.p.get('challenge'));
  assert.equal(Buffer.from(body.renewal_key, 'base64url').length, 65); assert.equal(Buffer.from(body.renewal_key, 'base64url')[0], 4);
  assert.equal(t.records.peek().deviceId, 'dev_1'); assert.equal(t.records.peek().privateKey.extractable, false);
  assert.equal(t.session.m.has('pending'), false); assert.equal(t.calls[0].o.credentials, 'omit');
});
test('failed, rejected or cancelled sign-in never replaces an existing record', async () => {
  for (const [identity, net] of [[goodIdentity(), async () => R(401, { error: 'invalid_grant' })], [goodIdentity(), async () => R(503)], [goodIdentity(), async () => { throw Error('net'); }], [undefined, undefined]]) {
    const t = mk({ identity, net }); t.records.put({ deviceId: 'old', privateKey: {}, publicKey: 'p' });
    const r = await t.auth.signIn(); assert.equal(r.ok, false); assert.equal(t.records.peek().deviceId, 'old'); assert.equal(t.session.m.has('pending'), false);
  }
});
test('a return with the wrong state or extra fields is refused before any exchange', async () => {
  const t = mk({ identity: { getRedirectURL: () => RU, launchWebAuthFlow: async () => RU + '#code=' + 'c'.repeat(43) + '&state=' + 'z'.repeat(43) } });
  assert.deepEqual(await t.auth.signIn(), { ok: false, error: 'invalid-return' }); assert.equal(t.calls.length, 0);
});
test('restart cancels the older pending flow: its late return is ignored', async () => {
  let release; const first = new Promise(r => { release = r; });
  let n = 0; const states = [];
  const identity = { getRedirectURL: () => RU, launchWebAuthFlow: async ({ url }) => { const p = new URLSearchParams(url.slice(url.indexOf('#') + 1)); states.push(p.get('state')); return n++ === 0 ? first.then(() => RU + '#code=' + 'c'.repeat(43) + '&state=' + states[0]) : RU + '#code=' + 'd'.repeat(43) + '&state=' + p.get('state'); } };
  const t = mk({ identity, net: async () => R(200, { device_id: 'dev_2', access: 'tok', access_expires_at: 1e12 + 300000 }) });
  const a = t.auth.signIn(); await new Promise(r => setTimeout(r, 5));
  const b = await t.auth.signIn(); release(); const a2 = await a;
  assert.deepEqual(b, { ok: true }); assert.deepEqual(a2, { ok: false, error: 'cancelled' });
  assert.equal(t.calls.filter(c => c.u.endsWith('/exchange')).length, 1);
});
test('recover() drops an orphaned pending flow after a worker restart', async () => {
  const t = mk(); await t.session.set('pending', { verifier: 'v', state: 's', created: 1 }); await t.auth.recover(); assert.equal(t.session.m.has('pending'), false);
});
test('partial records are signed out; status reflects the record', async () => {
  const t = mk(); assert.equal(await t.auth.status(), 'signed-out');
  t.records.put({ deviceId: 'x' }); assert.equal(await t.auth.status(), 'signed-out');
  t.records.put({ privateKey: {}, publicKey: 'p' }); assert.equal(await t.auth.status(), 'signed-out');
});
async function signedIn(net) {
  const t = mk({ identity: goodIdentity(), net });
  const key = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  t.records.put({ deviceId: 'dev_3', privateKey: key.privateKey, publicKey: 'p' }); return { t, key };
}
test('renew signs the exact domain string; 5xx, 429 and network errors keep the record; 401 clears it', async () => {
  let sig; const seen = [];
  const { t } = await signedIn(async (u, o) => {
    seen.push(u);
    if (u.endsWith('/challenge')) return R(200, { device_id: 'dev_3', nonce: 'n'.repeat(43), expires_at: 1e12 + 60000 });
    sig = JSON.parse(o.body); return R(200, { access: 'tok2', access_expires_at: 1e12 + 300000 });
  });
  const g = await t.auth.getAccess(); assert.equal(g.token, 'tok2');
  assert.deepEqual(Object.keys(sig).sort(), ['device_id', 'expires_at', 'nonce', 'signature']); assert.equal(Buffer.from(sig.signature, 'base64url').length, 64); assert.equal(sig.signature.length, 86);
  for (const bad of [() => R(503), () => R(429), () => { throw Error('offline'); }]) {
    const x = await signedIn(async () => bad()); const r = await x.t.auth.getAccess(true);
    assert.deepEqual(r, { state: 'unavailable' }); assert.ok(x.t.records.peek(), 'record kept');
  }
  const y = await signedIn(async u => (u.endsWith('/challenge') ? R(200, { device_id: 'dev_3', nonce: 'n', expires_at: 5 }) : R(401, { error: 'invalid_grant' })));
  assert.deepEqual(await y.t.auth.getAccess(true), { state: 'signed-out' }); assert.equal(y.t.records.peek(), undefined);
});
test('one renew in flight; a fresh bearer is reused; expiry margin triggers renew', async () => {
  let renews = 0;
  const { t } = await signedIn(async u => { if (u.endsWith('/challenge')) return R(200, { device_id: 'dev_3', nonce: 'n', expires_at: 5 }); renews++; return R(200, { access: 'tok' + renews, access_expires_at: 1e12 + 300000 }); });
  await Promise.all([t.auth.getAccess(), t.auth.getAccess(), t.auth.getAccess()]); assert.equal(renews, 1);
  await t.auth.getAccess(); assert.equal(renews, 1);
  t.tick(280000); await t.auth.getAccess(); assert.equal(renews, 2);
});
test('read allows only fixed GET paths, retries once after 401 with a renewed bearer, and never sends credentials', async () => {
  let reads = 0;
  const { t } = await signedIn(async (u, o) => {
    if (u.endsWith('/challenge')) return R(200, { device_id: 'dev_3', nonce: 'n', expires_at: 5 });
    if (u.endsWith('/renew')) return R(200, { access: 'tokR', access_expires_at: 1e12 + 300000 });
    reads++; return reads === 1 ? { status: 401, text: async () => '{}' } : { status: 200, text: async () => '{"ok":1}' };
  });
  for (const bad of ['/v1/manage/account', '/v1/manage/session', '/v1/manage/sources', '/v1/manage/unassigned', 'https://evil.example/']) { const u = await t.auth.read(bad); assert.deepEqual([u.status, u.unsupported], [503, true]); } assert.equal(t.calls.length, 0, 'unsupported paths never touch the network or renew');
  const r = await t.auth.read('/v1/manage/entries'); assert.equal(r.status, 200); assert.equal(reads, 2);
  const g = t.calls.filter(c => c.o.method === 'GET'); assert.ok(g.every(c => c.o.credentials === 'omit' && c.o.redirect === 'error' && c.o.headers.Authorization.startsWith('Bearer ')));
});
test('logout asks the server first (signed), and a server failure cannot block local cleanup', async () => {
  const order = [];
  const { t } = await signedIn(async u => { order.push(u.split('/').pop() + (t_has(t) ? '+rec' : '-rec')); if (u.endsWith('/challenge')) return R(200, { device_id: 'dev_3', nonce: 'n', expires_at: 5 }); throw Error('server down'); });
  function t_has(x) { return !!x.records.peek(); }
  await t.session.set('access', { token: 'a', expiresAt: 9e12 });
  await t.auth.logout();
  assert.deepEqual(order, ['challenge+rec', 'logout+rec']); assert.equal(t.records.peek(), undefined); assert.equal(t.session.m.has('access'), false);
});
test('transient renew failure backs off at least 10s, shared via session storage, so attempts stay under the nonce cap', async () => {
  let attempts = 0;
  const { t } = await signedIn(async () => { attempts++; return R(503); });
  assert.deepEqual(await t.auth.getAccess(true), { state: 'unavailable' }); assert.equal(attempts, 1);
  for (let i = 0; i < 50; i++) await t.auth.getAccess(true); assert.equal(attempts, 1, 'burst of reads inside the backoff makes no network calls');
  t.tick(9000); await t.auth.getAccess(true); assert.equal(attempts, 1);
  t.tick(1500); await t.auth.getAccess(true); assert.equal(attempts, 2);
  let total = 0, i = 0; const x = await signedIn(async () => { total++; return R(503); });
  for (; i < 600; i++) { await x.t.auth.getAccess(true); x.t.tick(1000); }
  assert.ok(total <= 6 * 10 + 1, 'at most 6 attempts a minute: ' + total); assert.ok(x.t.records.peek(), 'record kept');
  // A worker restart is a new auth object over the same session storage: still backed off.
  const y = await signedIn(async () => R(503)); await y.t.auth.getAccess(true);
  const again = createExtensionAuth({ api: API, webUrl: WEB, redirectKey: 'chrome', identity: goodIdentity(), fetch: async () => { throw Error('must not call'); }, records: y.t.records, session: y.t.session, now: () => 1e12 + 100 });
  assert.deepEqual(await again.getAccess(true), { state: 'unavailable' });
});
test('bearer validity is receipt time plus 300s minus margin; a skewed server absolute expiry is never compared to the local clock', async () => {
  let renews = 0;
  const far = async u => { if (u.endsWith('/challenge')) return R(200, { device_id: 'dev_3', nonce: 'n', expires_at: 5 }); renews++; return R(200, { access: 'tok' + renews, access_expires_at: 0 + 1 }); };
  const { t } = await signedIn(far);
  await t.auth.getAccess(); assert.equal(renews, 1);
  t.tick(200000); await t.auth.getAccess(); assert.equal(renews, 1, 'server expiry in the past is ignored');
  t.tick(80000); await t.auth.getAccess(); assert.equal(renews, 2, 'renews inside the margin');
  const { t: t2 } = await signedIn(async u => (u.endsWith('/challenge') ? R(200, { device_id: 'dev_3', nonce: 'n', expires_at: 5 }) : R(200, { access: 'z', access_expires_at: 4e15 })));
  await t2.auth.getAccess(); t2.tick(280000); await t2.auth.getAccess(); assert.ok(t2.calls.filter(c => c.u.endsWith('/renew')).length === 2, 'a far-future server expiry cannot extend the local lifetime');
  await t2.session.set('access', { token: 'tk', receivedAt: 1e12 + 5e6 }); assert.equal((await t2.auth.getAccess()).token !== 'tk', true, 'a receipt time in the future is not fresh');
});
test('final 401 on a read is never reported as signed out; only a cleared record is', async () => {
  const { t } = await signedIn(async (u, o) => (u.endsWith('/challenge') ? R(200, { device_id: 'dev_3', nonce: 'n', expires_at: 5 }) : u.endsWith('/renew') ? R(200, { access: 'tk', access_expires_at: 1 }) : { status: 401, text: async () => '{}' }));
  const r = await t.auth.read('/v1/manage/entries'); assert.deepEqual([r.status, r.signedOut], [503, undefined]); assert.ok(t.records.peek());
  const y = await signedIn(async u => (u.endsWith('/challenge') ? R(200, { device_id: 'dev_3', nonce: 'n', expires_at: 5 }) : R(401, { error: 'invalid_grant' })));
  const r2 = await y.t.auth.read('/v1/manage/entries'); assert.deepEqual([r2.status, r2.signedOut], [401, true]); assert.equal(y.t.records.peek(), undefined);
});
test('re-sign-in best-effort logs out the replaced device and a failed old logout does not matter', async () => {
  const seen = [];
  const t = mk({ identity: goodIdentity(), net: async (u, o) => { seen.push(u.split('/').pop() + ':' + (o.body ? JSON.parse(o.body).device_id ?? '' : '')); if (u.endsWith('/exchange')) return R(200, { device_id: 'dev_new', access: 'tok', access_expires_at: 1 }); if (u.endsWith('/challenge')) return R(200, { device_id: 'dev_old', nonce: 'n', expires_at: 5 }); throw Error('down'); } });
  const key = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  t.records.put({ deviceId: 'dev_old', privateKey: key.privateKey, publicKey: 'p' });
  assert.deepEqual(await t.auth.signIn(), { ok: true }); await new Promise(r => setTimeout(r, 20));
  assert.equal(t.records.peek().deviceId, 'dev_new'); assert.ok(seen.includes('challenge:dev_old') && seen.includes('logout:dev_old'));
});
test('client read allowlist matches the API source (set OTPANDA_API_SRC to a checkout; skipped without it)', async t => {
  const { readFile } = await import('node:fs/promises');
  const { READ_PATHS } = await import('./extension-auth.mjs');
  const bridge = (await readFile(new URL('./extension-session.js', import.meta.url), 'utf8')).match(/READ_PATHS = \[(.*?)\]/)[1].match(/'[^']+'/g).map(x => x.slice(1, -1));
  assert.deepEqual([...bridge].sort(), [...READ_PATHS].sort(), 'popup bridge and worker agree');
  if (!process.env.OTPANDA_API_SRC) return t.skip('no API checkout');
  const dir = process.env.OTPANDA_API_SRC;
  const reads = (await readFile(dir + '/src/device-read-http.js', 'utf8')).match(/EXT_PATHS=new Set\(\[(.*?)\]\)/)[1].match(/'[^']+'/g).map(x => x.slice(1, -1));
  const dom = (await readFile(dir + '/src/entry-domains-http.js', 'utf8')).match(/PATH='([^']+)'/)[1];
  assert.deepEqual([...reads, dom].sort(), [...READ_PATHS].sort());
});
