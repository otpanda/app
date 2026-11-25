// Real-browser test: packaged sign-in extension in real Chromium (headed under Xvfb), real identity window, real
// IndexedDB non-extractable key, real browser restart. Server side is the contract stand-in, not the real API.
// Needs: playwright (npm), Xvfb, openssl. Run: xvfb-run -a node tool/extension/e2e/e2e.mjs
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, cp, writeFile, rm } from 'node:fs/promises';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { startStandin } from './standin-api.mjs';

const { chromium } = await import(process.env.PLAYWRIGHT_ENTRY ?? 'playwright');
const here = import.meta.dirname, toolDir = path.resolve(here, '../..');
const tmp = await mkdtemp(path.join(os.tmpdir(), 'otpanda-ext-e2e-'));
const API = 'https://otpanda-api.abrahammurciano.workers.dev', WEB = 'https://otpanda.github.io/app/';
// Certificate for both hostnames (test only).
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', tmp + '/k.pem', '-out', tmp + '/c.pem', '-days', '2', '-subj', '/CN=otpanda.github.io', '-addext', 'subjectAltName=DNS:otpanda.github.io,DNS:otpanda-api.abrahammurciano.workers.dev'], { stdio: 'ignore' });
// Package the real way, over a stub web build.
const root = tmp + '/root';
await mkdir(root + '/tool/extension', { recursive: true }); await mkdir(root + '/build/web', { recursive: true });
for (const f of ['package.mjs', 'extension-auth.mjs', 'background.js', 'extension-session.js']) await cp(path.join(toolDir, 'extension', f), root + '/tool/extension/' + f);
if (process.env.E2E_REAL_BUILD) {
  // Real compiled Flutter app (flutter build web --csp ...) instead of the stub page.
  await rm(root + '/build/web', { recursive: true, force: true }); await cp(process.env.E2E_REAL_BUILD, root + '/build/web', { recursive: true });
} else {
  for (const i of ['otty-favicon-v2-16.png', 'otty-favicon-v2-32.png']) await writeFile(root + '/build/web/' + i, 'x');
  await writeFile(root + '/build/web/index.html', '<html><head></head><body><script src="session-bootstrap.js"></script><script src="flutter_bootstrap.js"></script></body></html>');
  await writeFile(root + '/build/web/session-bootstrap.js', 'x'); await writeFile(root + '/build/web/realtime-client.js', 'x');
  await writeFile(root + '/build/web/flutter_bootstrap.js', 'window._flutter={loader:{load(){}}};\n_flutter.loader.load({});');
}
const env = { ...process.env, ...(process.env.E2E_MANIFEST_KEY ? { OTPANDA_EXTENSION_MANIFEST_KEY: process.env.E2E_MANIFEST_KEY } : {}), OTPANDA_EXTENSION_SIGNIN: '1', OTPANDA_EXTENSION_API: API, OTPANDA_EXTENSION_WEB: WEB };
execFileSync(process.execPath, [root + '/tool/extension/package.mjs'], { env, stdio: 'inherit' });
const extDir = root + '/build/extension-preview';
const manifest = JSON.parse((await import('node:fs/promises')).readFile ? await (await import('node:fs/promises')).readFile(extDir + '/manifest.json', 'utf8') : '{}');

const flags = ['--no-sandbox', '--ignore-certificate-errors', `--host-resolver-rules=MAP otpanda.github.io 127.0.0.1:8443, MAP otpanda-api.abrahammurciano.workers.dev 127.0.0.1:8443`, '--disable-extensions-except=' + extDir, '--load-extension=' + extDir];
const profile = tmp + '/profile';
const launch = () => chromium.launchPersistentContext(profile, { headless: false, args: flags });
const results = [];
const ok = (name, detail = '') => { results.push(name); console.log('PASS ' + name + (detail ? ' :: ' + detail : '')); };
const extId = c => c.serviceWorkers()[0] ? new URL(c.serviceWorkers()[0].url()).host : undefined;
const getSw = async c => { let [sw] = c.serviceWorkers(); if (!sw) sw = await c.waitForEvent('serviceworker'); return sw; };
const authWindowFor = async (c, url) => { for (let i = 0; i < 150; i++) { const p = c.pages().find(x => x.url().startsWith(url)); if (p) return p; await new Promise(r => setTimeout(r, 100)); } throw Error('window not found'); };
const authWindow = async c => { for (let i = 0; i < 150; i++) { const p = c.pages().find(x => x.url().startsWith(WEB)); if (p) return p; await new Promise(r => setTimeout(r, 100)); } throw Error('identity window not found'); };
const popupErrors = [];
const popup = async (c, id) => { const p = await c.newPage(); p.on('pageerror', e => popupErrors.push('pageerror ' + e.message)); p.on('console', m => { if (m.type() === 'error') popupErrors.push('console ' + m.text()); }); await p.goto(`chrome-extension://${id}/index.html`); await p.evaluate(() => OTPandaSession.ready); return p; };

process.on('unhandledRejection', () => {});
let ctx = await launch();
let sw = await getSw(ctx);
const id = extId(ctx);
if (process.env.E2E_MANIFEST_KEY) {
  // Chrome's documented derivation: sha256 of the DER public key, first 32 hex digits mapped 0-f to a-p. The browser must agree.
  const { createHash } = await import('node:crypto');
  const expected = [...createHash('sha256').update(Buffer.from(process.env.E2E_MANIFEST_KEY, 'base64')).digest('hex').slice(0, 32)].map(h => String.fromCharCode(97 + parseInt(h, 16))).join('');
  assert.equal(id, expected); console.log('PASS stable ID from manifest key matches the browser: ' + id);
}
const redirectUri = `https://${id}.chromiumapp.org/`;
const redirects = { chrome: redirectUri };
let real;
if (process.env.OTPANDA_API_SRC) {
  const { realApi } = await import('./real-api.mjs');
  real = await realApi(process.env.OTPANDA_API_SRC, { redirects, extensionOrigin: 'chrome-extension://' + id });
  console.log('USING REAL API SOURCE', process.env.OTPANDA_API_SRC);
}
const api = await startStandin({ pagesRoot: toolDir, cert: tmp + '/c.pem', key: tmp + '/k.pem', redirects, real });
api.pinnedOrigin = 'chrome-extension://' + id;
try {
  console.log('browser', ctx.browser()?.version?.() ?? '', 'ext id', id, 'permissions', JSON.stringify(manifest.permissions), JSON.stringify(manifest.host_permissions));
  // 1. The web user is already signed in on Pages (stand-in restore sets nothing; the hint makes the bootstrap restore).
  const web = await ctx.newPage();
  await web.goto(WEB); await web.evaluate(() => localStorage.setItem('otpanda-session-present', 'yes'));
  await web.close();
  let pop = await popup(ctx, id);
  assert.equal(await pop.evaluate(() => OTPandaSession.status()), 'idle'); ok('fresh install is signed out');
  if (process.env.E2E_REAL_BUILD) { await pop.setViewportSize({ width: 390, height: 600 }); await new Promise(r => setTimeout(r, 4000)); await pop.screenshot({ path: '/tmp/popup-signed-out.png' }); }

  // 2. Window close cancels cleanly and clears the pending flow.
  const cancelled = pop.evaluate(async () => { try { await OTPandaSession.start('login'); return 'resolved'; } catch (e) { return String(e.message); } });
  const win = await authWindow(ctx);
  await win.close();
  assert.equal(await cancelled, 'cancelled');
  assert.equal(await sw.evaluate(async () => (await chrome.storage.session.get('pending')).pending), undefined);
  assert.equal(await pop.evaluate(() => OTPandaSession.status()), 'idle'); assert.equal(api.exchanges, 0); ok('closing the identity window cancels, clears pending, signs nothing in');

  // 3. Full sign-in: window -> web restores -> user clicks Connect -> begin -> redirect -> exchange.
  const done = pop.evaluate(async () => { try { await OTPandaSession.start('login'); return 'ok'; } catch (e) { return String(e.message); } });
  const w = await authWindow(ctx);
  await w.waitForSelector('#connect', { timeout: 8000 }).catch(async () => { console.log('DEBUG', await w.evaluate(() => JSON.stringify({ t: document.getElementById('s')?.textContent, ls: { ...localStorage }, ss: { ...sessionStorage }, url: location.href }))); throw Error('no connect button'); });
  assert.equal(api.log.filter(l => l.path === '/auth/extension/begin' && l.method === 'POST').length, 0, 'begin only after the click');
  assert.ok(!w.url().includes('extension='), 'fragment removed from the address bar: ' + w.url());
  await w.click('#connect');
  assert.equal(await done, 'ok'); ok('sign-in through the real identity window, begin only after the Connect click');
  const begin = api.log.find(l => l.path === '/auth/extension/begin' && l.method === 'POST');
  assert.equal(begin.origin, 'https://otpanda.github.io'); assert.equal(begin.status, 200);
  const ex = api.log.find(l => l.path === '/auth/extension/exchange'); assert.equal(ex.status, 200);
  ok('server saw begin from the Pages origin and exchange with Origin ' + (ex.origin ?? '(absent)'));
  assert.equal(await pop.evaluate(() => OTPandaSession.status()), 'restored');

  // 4. Key is non-extractable and lives with the device id in one IDB record; content/page cannot see it.
  const rec = await sw.evaluate(async () => {
    const db = await new Promise((r, j) => { const q = indexedDB.open('otpanda-extension-v1', 1); q.onsuccess = () => r(q.result); q.onerror = j; });
    const v = await new Promise(r => { const q = db.transaction('record').objectStore('record').get('device'); q.onsuccess = () => r(q.result); });
    let exported = 'refused'; try { await crypto.subtle.exportKey('pkcs8', v.privateKey); exported = 'EXPORTED'; } catch {}
    return { keys: Object.keys(v).sort(), extractable: v.privateKey.extractable, algo: v.privateKey.algorithm.name, deviceId: typeof v.deviceId, exported, pub: v.publicKey.length };
  });
  assert.deepEqual(rec, { keys: ['created', 'deviceId', 'privateKey', 'publicKey'], extractable: false, algo: 'ECDSA', deviceId: 'string', exported: 'refused', pub: 87 });
  ok('record: one IDB record with deviceId + non-extractable CryptoKey + public key; pkcs8 export refused', JSON.stringify(rec));
  const sessionKeys = await sw.evaluate(async () => Object.keys(await chrome.storage.session.get(null)).sort());
  assert.deepEqual(sessionKeys, ['access']); ok('session storage holds only the access bearer after sign-in (PKCE pending removed)');
  const webPage = await ctx.newPage(); await webPage.goto(WEB);
  assert.equal(await webPage.evaluate(() => typeof chrome?.runtime?.sendMessage), 'undefined'); await webPage.close(); ok('an ordinary web page cannot message the extension');

  // 5. Reads through the worker.
  let r = await pop.evaluate(() => OTPandaSession.read('/v1/manage/entries')); assert.equal(r.status, 200);
  const nets = api.log.length;
  for (const bad of ['/v1/manage/account', '/v1/manage/session', '/v1/manage/sources', '/v1/manage/unassigned', '/v1/manage/organization']) { const u = await pop.evaluate(p => OTPandaSession.read(p), bad); assert.equal(u.status, 503); }
  assert.equal(api.log.length, nets); assert.equal(await pop.evaluate(() => OTPandaSession.status()), 'restored');
  r = await pop.evaluate(() => OTPandaSession.read('/v1/manage/entry/domains')); assert.equal(r.status, 200);
  ok('GET reads of the three API routes through the worker; any other path is a local 503 with no network and no state change');
  const read = api.log.find(l => l.path === '/v1/manage/entries'); assert.equal(read.origin, undefined === read.origin ? undefined : read.origin);
  console.log('INFO read request Origin header seen by server:', read.origin ?? '(absent)', 'POST exchange Origin:', ex.origin ?? '(absent)');
  const preflights = api.log.filter(l => l.method === 'OPTIONS' && l.path.startsWith('/auth/extension/') && l.path !== '/auth/extension/begin' ); assert.equal(preflights.length, 0); ok('no CORS preflight reached the token routes (host permission path)');

  // 6. Worker restart inside a session: access bearer survives in session storage, no renew needed.
  const cdp = await ctx.newCDPSession(pop); await cdp.send('ServiceWorker.enable');
  await cdp.send('ServiceWorker.stopAllWorkers');
  const before = api.log.filter(l => l.path === '/auth/extension/renew').length;
  r = await pop.evaluate(() => OTPandaSession.read('/v1/manage/entries')); assert.equal(r.status, 200);
  assert.equal(api.log.filter(l => l.path === '/auth/extension/renew').length, before); ok('stopped and restarted worker keeps the session with no renew');

  // 7. Browser restart: bearer gone, key+id survive, silent signed renew with no re-login.
  await pop.close(); await ctx.close(); ctx = await launch(); sw = await getSw(ctx);
  assert.equal(extId(ctx), id);
  assert.deepEqual(await sw.evaluate(async () => Object.keys(await chrome.storage.session.get(null))), []); ok('browser restart clears session storage');
  pop = await popup(ctx, id);
  assert.equal(await pop.evaluate(() => OTPandaSession.status()), 'restored');
  r = await pop.evaluate(() => OTPandaSession.read('/v1/manage/entries')); assert.equal(r.status, 200);
  const renews = api.log.filter(l => l.path === '/auth/extension/renew'); assert.equal(renews.length, 1); assert.equal(renews[0].status, 200);
  assert.equal(api.exchanges, 1); ok('after browser restart: challenge + signed renew with the persisted key, no new sign-in, one exchange total');

  // 8. Transient errors keep the record; invalid_grant clears it.
  await sw.evaluate(async () => { await chrome.storage.session.remove('access'); });
  api.mode.challenge = '503';
  r = await pop.evaluate(() => OTPandaSession.read('/v1/manage/entries')); assert.equal(r.status, 503);
  const chal = () => api.log.filter(l => l.path === '/auth/extension/challenge').length, c0 = chal();
  assert.deepEqual(await sw.evaluate(async () => Object.keys(await chrome.storage.session.get(null)).sort()), ['backoff']);
  for (let i = 0; i < 5; i++) { r = await pop.evaluate(() => OTPandaSession.read('/v1/manage/entries')); assert.equal(r.status, 503); }
  assert.equal(chal(), c0, 'reads inside the backoff make no challenge requests');
  assert.equal(await pop.evaluate(() => OTPandaSession.status()), 'restored', 'transient failure is not signed out');
  api.mode.challenge = 'ok'; await sw.evaluate(async () => { await chrome.storage.session.remove('backoff'); });
  assert.equal(await sw.evaluate(async () => { const db = await new Promise(r => { const q = indexedDB.open('otpanda-extension-v1', 1); q.onsuccess = () => r(q.result); }); return !!(await new Promise(r => { const q = db.transaction('record').objectStore('record').get('device'); q.onsuccess = () => r(q.result); })); }), true);
  r = await pop.evaluate(() => OTPandaSession.read('/v1/manage/entries')); assert.equal(r.status, 200); ok('503 keeps the record, backs off (no burst of challenges, not signed out); after the backoff the next read renews without sign-in');
  await api.revokeAll();
  await sw.evaluate(async () => { await chrome.storage.session.remove('access'); });
  r = await pop.evaluate(() => OTPandaSession.read('/v1/manage/entries')); assert.equal(r.status, 401);
  assert.equal(await sw.evaluate(async () => { const db = await new Promise(r => { const q = indexedDB.open('otpanda-extension-v1', 1); q.onsuccess = () => r(q.result); }); return !!(await new Promise(r => { const q = db.transaction('record').objectStore('record').get('device'); q.onsuccess = () => r(q.result); })); }), false);
  assert.equal(await pop.evaluate(() => OTPandaSession.status()), 'idle'); ok('invalid_grant (revoked) clears the record and signs out');

  // 9. Sign in again, then logout: server-side first, then local cleanup.
  const again = pop.evaluate(async () => { try { await OTPandaSession.start('login'); return 'ok'; } catch (e) { return String(e.message); } });
  const w2 = await authWindow(ctx); await w2.waitForSelector('#connect', { timeout: 20000 }); await w2.click('#connect');
  assert.equal(await again, 'ok'); assert.equal(api.exchanges, 2); ok('explicit re-sign-in after revocation works (new key, new device)');
  
  if (process.env.E2E_FLAP) {
    await pop.close();
    const wait = async (f, ms) => { for (let i = 0; i < ms / 100; i++) { if (await f()) return true; await new Promise(r => setTimeout(r, 100)); } return false; };
    const reads = () => api.log.filter(l => l.path === '/v1/manage/active-codes' && l.method === 'GET').length;
    const rtp = await popup(ctx, id); await rtp.setViewportSize({ width: 390, height: 600 });
    assert.ok(await wait(() => api.rt.sockets.size === 1, 15000)); await new Promise(r => setTimeout(r, 4500));
    // R1: accept-then-close flapping must neither refetch nor reset the backoff.
    api.rt.flap = true; const fc0 = reads(), fm0 = api.rt.mints; api.rt.close(1011); await new Promise(r => setTimeout(r, 20000)); api.rt.flap = false;
    const fm = api.rt.mints - fm0; assert.ok(fm >= 2 && fm <= 4, 'mints while flapping: ' + fm); assert.equal(reads(), fc0, 'no connect refetch from sockets that never stayed up 2s');
    ok('accept-then-close flapping: no refetch, backoff keeps growing (' + fm + ' mints in 20s)');
    assert.ok(await wait(() => api.rt.sockets.size === 1, 60000), 'recovers once the server behaves');
    await rtp.close(); pop = await popup(ctx, id);
  }
  if (process.env.E2E_TRAILING) {
    // Metadata budget (slow, run separately): a hint inside the 30s window does not refetch entries now; one trailing refetch follows.
    await pop.close();
    const wait = async (f, ms) => { for (let i = 0; i < ms / 100; i++) { if (await f()) return true; await new Promise(r => setTimeout(r, 100)); } return false; };
    const metas = () => api.log.filter(l => l.path === '/v1/manage/entries' && l.method === 'GET').length;
    const codes = () => api.log.filter(l => l.path === '/v1/manage/active-codes' && l.method === 'GET').length;
    const rtp = await popup(ctx, id); await rtp.setViewportSize({ width: 390, height: 600 });
    assert.ok(await wait(() => api.rt.sockets.size === 1, 15000)); await new Promise(r => setTimeout(r, 4000));
    const m0 = metas(), c0 = codes(), t0 = Date.now(); api.rt.hint(); await new Promise(r => setTimeout(r, 4000));
    assert.equal(codes() - c0, 1, 'codes refetched at once on the hint'); assert.equal(metas() - m0, 0, 'entries not refetched inside the 30s window');
    ok('hint inside the 30s window: codes refetched immediately, entries/domains not');
    assert.ok(await wait(() => metas() - m0 === 1, 40000), 'trailing entries refetch'); const dt = Date.now() - t0;
    assert.ok(dt >= 20000 && dt <= 38000, 'trailing refetch after ' + dt + 'ms'); await new Promise(r => setTimeout(r, 3000)); assert.equal(metas() - m0, 1, 'exactly one trailing refetch');
    ok('one trailing entries refetch after the 30s window (' + dt + 'ms after the hint)');
    await rtp.close(); pop = await popup(ctx, id);
  }
  if (process.env.E2E_REAL_BUILD && !process.env.E2E_TRAILING && !process.env.E2E_FLAP) {
    // Popup-lifetime realtime: socket only while the popup is open; hints refetch the three reads, coalesced; no timer poll.
    await pop.close(); // one popup only: a second open popup would be a second socket and second reader
    const wait = async (f, ms = 15000) => { for (let i = 0; i < ms / 100; i++) { if (await f()) return true; await new Promise(r => setTimeout(r, 100)); } return false; };
    const reads = () => api.log.filter(l => l.path === '/v1/manage/active-codes' && l.method === 'GET').length;
    const metas = () => api.log.filter(l => ['/v1/manage/entries', '/v1/manage/entry/domains'].includes(l.path) && l.method === 'GET').length;
    const rtp = await popup(ctx, id); await rtp.setViewportSize({ width: 390, height: 600 });
    if (!(await wait(() => api.rt.sockets.size === 1))) throw Error('no socket: mints=' + api.rt.mints + ' upgrades=' + JSON.stringify(api.rt.upgrades) + ' errs=' + JSON.stringify(popupErrors.slice(-4)) + ' st=' + await rtp.evaluate(() => OTPandaSession.status()));
    assert.equal(api.rt.upgrades.at(-1).origin, 'chrome-extension://' + id); assert.equal(api.rt.upgrades.at(-1).offered, 2);
    await new Promise(r => setTimeout(r, 4500)); const r0 = reads(); assert.ok(r0 >= 1); assert.equal(await rtp.evaluate(() => 1), 1);
    ok('popup open: one-use ticket from the worker, wss upgrade with the extension origin, data fetched on open/connect (not the bearer in the socket)');
    const quiet = reads(), qm = metas(); const marks = []; for (let i = 0; i < 14; i++) { await new Promise(r => setTimeout(r, 1000)); marks.push(reads()); } assert.equal(marks.at(-1), quiet, 'quiet window reads: ' + marks.join(',')); assert.equal(reads(), quiet, JSON.stringify(api.log.slice(-12).map(l => l.method + ' ' + l.path + ' ' + l.status))); assert.equal(metas(), qm); ok('no timer polling: no reads in 14s with a live socket');
    for (let i = 0; i < 5; i++) api.rt.hint(); await new Promise(r => setTimeout(r, 3500));
    const r1 = reads() - r0; assert.equal(metas() - qm, 0, 'no metadata refetch inside the 30s window'); assert.ok(r1 >= 1 && r1 <= 2, 'burst of 5 hints coalesced into ' + r1);
    ok('5 content-free hints coalesce into ' + r1 + ' refresh batch(es) of codes; entries/domains not refetched inside 30s');

    api.rt.hint('{"v":1,"t":"x"}'); assert.ok(await wait(() => api.rt.sockets.size === 0, 5000)); ok('any frame other than the exact hint closes the socket');
    assert.ok(await wait(() => api.rt.sockets.size === 1, 15000), 'reconnect tl ' + JSON.stringify(api.rt.times) + JSON.stringify(api.rt.upgrades.map(u => u.t)) + ' now=' + (Date.now() % 100000) + ' sockets=' + api.rt.sockets.size + ' errs=' + JSON.stringify(popupErrors.slice(-3))); ok('socket reconnects after a protocol error (5s-5min jittered backoff)');
    const m0 = api.rt.mints; api.rt.close(1011); assert.ok(await wait(() => api.rt.sockets.size === 0, 3000), 'tl ' + JSON.stringify(api.rt.times) + JSON.stringify(api.rt.upgrades.map(u => u.t)) + ' now=' + (Date.now() % 100000)); await new Promise(r => setTimeout(r, 1000));
    assert.equal(api.rt.mints, m0, 'no instant reconnect burst ' + JSON.stringify(api.rt.times) + ' now=' + (Date.now() % 100000) + ' m0=' + m0); assert.ok(await wait(() => api.rt.sockets.size === 1, 15000), 'reconnect tl ' + JSON.stringify(api.rt.times) + JSON.stringify(api.rt.upgrades.map(u => u.t)) + ' now=' + (Date.now() % 100000) + ' sockets=' + api.rt.sockets.size + ' errs=' + JSON.stringify(popupErrors.slice(-3))); const afterReconnect = reads(); ok('server close: reconnect with a fresh ticket, one mint per attempt');
    await new Promise(r => setTimeout(r, 1500)); assert.ok(reads() > quiet, 'refetch after reconnect');
    const hasRecord = () => sw.evaluate(async () => { const db = await new Promise(r => { const q = indexedDB.open('otpanda-extension-v1', 1); q.onsuccess = () => r(q.result); }); return !!(await new Promise(r => { const q = db.transaction('record').objectStore('record').get('device'); q.onsuccess = () => r(q.result); })); });
    api.rt.close(4401); assert.ok(await wait(() => api.rt.sockets.size === 0, 3000)); assert.ok(await wait(() => api.rt.sockets.size === 1, 20000));
    assert.equal(await hasRecord(), true); assert.equal(await rtp.evaluate(() => OTPandaSession.status()), 'restored'); ok('socket 4401 never clears the record: forced signed renew, then reconnect');
    await rtp.close(); assert.ok(await wait(() => api.rt.sockets.size === 0, 3000)); ok('closing the popup closes the socket (nothing runs in the worker)');
    const rtp2 = await popup(ctx, id); assert.ok(await wait(() => api.rt.sockets.size === 1)); await new Promise(r => setTimeout(r, 1500)); await rtp2.close();
    ok('reopening the popup re-tickets and catches up'); assert.ok(await wait(() => api.rt.sockets.size === 0, 3000));
    api.rt.mintStatus = 503; const mm = api.rt.mints; const rtp3 = await popup(ctx, id); await rtp3.setViewportSize({ width: 390, height: 600 }); await new Promise(r => setTimeout(r, 9000));
    const mt = api.rt.times.filter(x => typeof x === 'number').slice(-(api.rt.mints - mm)); const gaps = mt.slice(1).map((x, i) => (x - mt[i] + 100000) % 100000); assert.ok(api.rt.mints - mm <= 4 && gaps.every(g => g >= 2300), 'mint gaps while the ticket route is down: ' + JSON.stringify(mt)); assert.equal(await hasRecord(), true); await rtp3.screenshot({ path: '/tmp/popup-live-paused.png' }); await rtp3.close(); api.rt.mintStatus = 200;
    ok('ticket route down: jittered, spaced mint attempts (>=2.3s apart), record kept, "Live updates paused" shown');
    pop = await popup(ctx, id);
  }
  // Bounded profile/cookie probe of the real identity window (not a provider or passkey test).
  { const CP = WEB + 'cookie-probe.html'; api.cookieSeen = [];
    const tab = await ctx.newPage(); await tab.goto(CP); await tab.close(); // ordinary tab sets the cookie
    sw.evaluate(u => chrome.identity.launchWebAuthFlow({ url: u, interactive: true }).catch(() => {}), CP);
    const iw = await authWindowFor(ctx, CP); await new Promise(r => setTimeout(r, 800)); await iw.close();
    assert.deepEqual(api.cookieSeen, [false, true]); ok('identity window shares the profile cookies of an ordinary tab (cookie sent on the first request)');
    await ctx.clearCookies(); api.cookieSeen = [];
    sw.evaluate(u => chrome.identity.launchWebAuthFlow({ url: u, interactive: true }).catch(() => {}), CP);
    const iw2 = await authWindowFor(ctx, CP); await new Promise(r => setTimeout(r, 800)); await iw2.close();
    const tab2 = await ctx.newPage(); await tab2.goto(CP); await tab2.close();
    assert.deepEqual(api.cookieSeen, [false, true]); ok('a cookie set inside the identity window is visible to ordinary tabs afterwards (same profile jar)'); }
  if (process.env.E2E_REAL_BUILD) { const p2 = await popup(ctx, id); await p2.setViewportSize({ width: 390, height: 600 }); await new Promise(r => setTimeout(r, 5000)); await p2.screenshot({ path: '/tmp/popup-signed-in.png' }); await p2.bringToFront(); await p2.mouse.click(315, 96); await new Promise(r => setTimeout(r, 800)); const tp = await ctx.newPage(); await tp.goto('data:text/html,<textarea id=t autofocus></textarea>'); await tp.focus('#t'); await tp.keyboard.press('Control+V'); await new Promise(r => setTimeout(r, 300)); const clip = await tp.inputValue('#t'); await tp.close(); await p2.bringToFront(); assert.equal(clip, '123456'); ok('popup Copy click puts the real code on the clipboard'); await p2.mouse.click(350, 28); await p2.waitForFunction(() => OTPandaSession.status() === 'idle', null, { timeout: 8000 }); for (let i = 0; i < 50 && !api.lastRevoked(); i++) await new Promise(r => setTimeout(r, 100)); assert.equal(api.lastRevoked(), true); ok('popup Sign out button: signed server revoke and signed-out state'); await new Promise(r => setTimeout(r, 1500)); await p2.screenshot({ path: '/tmp/popup-after-signout.png' }); console.log('INFO popup text:', JSON.stringify((await p2.evaluate(() => document.body.innerText)).slice(0, 300)), 'errors:', JSON.stringify(popupErrors.slice(0, 5))); await p2.close(); }
  pop.evaluate(() => OTPandaSession.logout());
  await pop.waitForFunction(() => OTPandaSession.status() === 'idle');
  for (let i = 0; i < 50 && !api.lastRevoked(); i++) await new Promise(r => setTimeout(r, 100));
  assert.equal(api.lastRevoked(), true);
  assert.equal(await sw.evaluate(async () => { const db = await new Promise(r => { const q = indexedDB.open('otpanda-extension-v1', 1); q.onsuccess = () => r(q.result); }); return !!(await new Promise(r => { const q = db.transaction('record').objectStore('record').get('device'); q.onsuccess = () => r(q.result); })); }), false);
  assert.deepEqual(await sw.evaluate(async () => Object.keys(await chrome.storage.session.get(null))), []); ok('logout: signed server revoke, then record and bearer removed locally');
  console.log('\nALL PASS', results.length);
} catch (e) {
  console.error('FAIL', e?.message ?? e); console.error(JSON.stringify(api.log.slice(-8))); process.exitCode = 1;
} finally {
  await ctx.close().catch(() => {}); await api.close(); real?.close(); await rm(tmp, { recursive: true, force: true });
}
