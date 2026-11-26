// Local, synthetic-only API for the Android Keystore round-trip test.
// Runs the real auth-only Worker (src/auth-only-worker.js) in Miniflare with a
// real D1 (SQLite) and the repo's migrations, and exposes it on 127.0.0.1.
// The emulator reaches it through `adb reverse tcp:PORT tcp:PORT`.
// Nothing here talks to production, to Google, or to any real account.
//
//   node tool/native-roundtrip-harness.mjs [--port 8787]
//
// Control endpoints (harness only, never part of the Worker):
//   POST /__harness/seed          -> {ownerId, entryId, sourceId, code}
//   POST /__harness/mint {challenge} -> {code}   (stands in for the browser leg)
//   GET  /__harness/entry?id=...  -> {label, account}
//   GET  /__harness/devices       -> {devices:[{deviceId, clientKind, revoked}]}
//   POST /__harness/expire-access -> {expired}   (lifecycle test control)
//        Expires every android access handle IN D1, so the Worker rejects the
//        bearer the client still believes is valid. This is a D1 state edit,
//        NOT a real 5 minute wait and NOT a Worker clock change.
//   POST /__harness/revoke-device -> {revoked}    (lifecycle test control)
//        Sets revoked_at on every android device session in D1, as a blocked
//        or revoked enrollment would look to the Worker. Synthetic only.
//   GET  /__harness/health        -> {ok:true}
import {Miniflare, convertV4MiniflareOptions} from 'miniflare';
import * as esbuild from 'esbuild';
import {readFileSync, readdirSync} from 'node:fs';
import {createServer} from 'node:http';
import {fileURLToPath} from 'node:url';
import {dirname, join} from 'node:path';
import {AccountIdentityService} from '../src/account-identity.js';
import {PasskeySignupService} from '../src/passkey-signup.js';
import {DeviceSessionService} from '../src/device-sessions.js';
import {NativeSessionService, NATIVE_REDIRECT} from '../src/native-sessions.js';
import {SourceEntryStore} from '../src/source-entries.js';
import {CodeCipher} from '../src/code-cipher.js';
import {base64urlEncode} from '../src/tokens.js';
import {authenticator} from '../test/passkey-fixture.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (n, d) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : d; };
const PORT = Number(arg('port', '8787'));
const config = JSON.parse(readFileSync(join(root, 'wrangler.jsonc'), 'utf8').replace(/^\s*\/\/.*$/gm, ''));

// Apply migrations in order. A statement ends at ';' at a line end, except
// CREATE TRIGGER, which runs to its closing END;
function migrationStatements() {
  const out = [];
  for (const f of readdirSync(join(root, 'migrations')).filter(n => n.endsWith('.sql')).sort()) {
    let cur = '', trigger = false;
    for (const line of readFileSync(join(root, 'migrations', f), 'utf8').split('\n')) {
      if (/^\s*--/.test(line)) continue;
      cur += line + '\n';
      if (/^\s*CREATE\s+(TEMP\s+|TEMPORARY\s+)?TRIGGER\b/i.test(line)) trigger = true;
      const done = trigger ? /^\s*END\s*;\s*$/i.test(line) : /;\s*$/.test(line);
      if (done) { if (cur.trim()) out.push(cur.trim()); cur = ''; trigger = false; }
    }
    if (cur.trim()) out.push(cur.trim());
  }
  return out;
}

const bundle = await esbuild.build({
  entryPoints: [join(root, 'src/auth-only-worker.js')], bundle: true, format: 'esm',
  platform: 'browser', write: false,
});
const keyBytes = new Uint8Array(32).fill(11);
const options = await convertV4MiniflareOptions({
  modules: true, script: bundle.outputFiles[0].text,
  compatibilityDate: config.compatibility_date, compatibilityFlags: ['nodejs_compat'],
  d1Databases: ['DB'],
  durableObjects: {REALTIME_HUB: {className: 'RealtimeHub', useSQLite: true}},
  bindings: {
    ...config.vars,
    ACTIVE_KEY_ID: 'synthetic',
    ENCRYPTION_KEYRING: JSON.stringify([{id: 'synthetic', key: Buffer.from(keyBytes).toString('base64url')}]),
    NATIVE_AUTH_ENABLED: '1',
    // Not used by exchange/renew/reads. Present so the native gate config is whole.
    NATIVE_ASSET_FINGERPRINTS: '05:C6:2F:2D:61:FB:DC:15:0F:DD:DA:58:E7:FB:C8:36:65:0A:65:74:3A:B5:3F:13:93:AE:08:D5:5C:A8:59:99',
    GOOGLE_CLIENT_SECRET: 'synthetic', BREVO_API_KEY: 'synthetic',
  },
  ratelimits: Object.fromEntries((config.ratelimits ?? []).map(({name, ...o}) => [name, {...o, simple: {limit: 10000, period: 60}}])),
});
options.workers[0].dev.outboundService = {type: 'fetcher', handler: async r => { throw Error('Unexpected outbound request ' + r.url); }};
const mf = new Miniflare(options);
const db = await mf.getD1Database('DB');
for (const sql of migrationStatements()) await db.prepare(sql).run();

const clock = () => Date.now();
let seeded;
async function seed() {
  if (seeded) return seeded;
  const now = Date.now(), a = authenticator();
  const signup = new PasskeySignupService(db, {clock}), identity = new AccountIdentityService(db, {clock});
  const ec = await identity.issueEmailChallenge({purpose: 'signup-email', email: 'alex@example.test'});
  const b = await signup.begin({email: 'alex@example.test', emailToken: ec.token, binding: 'harness'});
  const account = await signup.finish({token: b.token, binding: 'harness', response: a.registration({expected: b.options.challenge})});
  const sessions = new DeviceSessionService(db, {clock});
  const web = await sessions.issue({proof: {...account, verifiedAt: now, purpose: 'authenticate'}, clientKind: 'web'});
  const key = await crypto.subtle.importKey('raw', keyBytes, {name: 'AES-GCM'}, false, ['encrypt', 'decrypt']);
  const store = new SourceEntryStore(db, new CodeCipher({keys: new Map([['synthetic', key]]), activeKeyId: 'synthetic'}));
  const source = await store.createSource(account.ownerId, 'sms', 'Fictional phone', now);
  const entry = await store.createEntry(account.ownerId, 'fictional', 'Fictional service', now, {accountName: 'alex@example.test'});
  await store.receive(account.ownerId, {sourceId: source, eventId: 'seed-code', code: '123456', receivedAt: now, expiresAt: now + 3600000});
  await store.confirm(account.ownerId, source, 'seed-code', entry, now);
  seeded = {ownerId: account.ownerId, entryId: entry, sourceId: source, code: '123456', webDeviceId: web.deviceId};
  return seeded;
}

const json = (res, status, body) => { res.writeHead(status, {'content-type': 'application/json'}); res.end(JSON.stringify(body)); };
const readBody = async req => { const p = []; for await (const c of req) p.push(c); return Buffer.concat(p); };

const server = createServer(async (req, res) => {
  try {
    const u = new URL(req.url, 'http://127.0.0.1');
    if (u.pathname.startsWith('/__harness/')) {
      if (u.pathname === '/__harness/health') return json(res, 200, {ok: true});
      if (u.pathname === '/__harness/seed' && req.method === 'POST') {
        const s = await seed(); return json(res, 200, {ownerId: s.ownerId, entryId: s.entryId, sourceId: s.sourceId, code: s.code});
      }
      if (u.pathname === '/__harness/mint' && req.method === 'POST') {
        const s = await seed(), {challenge} = JSON.parse((await readBody(req)).toString());
        const m = await new NativeSessionService(db, {clock}).mint({sourceDeviceId: s.webDeviceId, challenge, redirectUri: NATIVE_REDIRECT});
        return m ? json(res, 200, {code: m.code}) : json(res, 400, {error: 'mint_refused'});
      }
      if (u.pathname === '/__harness/entry') {
        const r = await db.prepare('SELECT label, account_name FROM entries WHERE entry_id=?').bind(u.searchParams.get('id')).first();
        return json(res, r ? 200 : 404, r ? {label: r.label, account: r.account_name} : {});
      }
      if (u.pathname === '/__harness/devices') {
        const rows = (await db.prepare("SELECT device_id, client_kind, revoked_at FROM device_sessions WHERE client_kind='android'").all()).results;
        return json(res, 200, {devices: rows.map(r => ({deviceId: r.device_id, clientKind: r.client_kind, revoked: r.revoked_at != null}))});
      }
      if (u.pathname === '/__harness/expire-access' && req.method === 'POST') {
        const {deviceId} = JSON.parse((await readBody(req)).toString());
        if(typeof deviceId !== 'string') return json(res,400,{error:'device'});
        const r = await db.prepare("UPDATE device_access_handles SET expires_at=created_at+1 WHERE device_id=? AND device_id IN (SELECT device_id FROM device_sessions WHERE client_kind='android')").bind(deviceId).run();
        return json(res, 200, {expired: r.meta.changes});
      }
      if (u.pathname === '/__harness/revoke-device' && req.method === 'POST') {
        const {deviceId} = JSON.parse((await readBody(req)).toString());
        if(typeof deviceId !== 'string') return json(res,400,{error:'device'});
        const r = await db.prepare("UPDATE device_sessions SET revoked_at=?1 WHERE client_kind='android' AND device_id=?2 AND revoked_at IS NULL").bind(Date.now(),deviceId).run();
        return json(res, 200, {revoked: r.meta.changes});
      }
      return json(res, 404, {});
    }
    const body = await readBody(req);
    const headers = {...req.headers, 'CF-Connecting-IP': '192.0.2.50'};
    delete headers.host;
    const r = await mf.dispatchFetch('https://otpanda-api.abrahammurciano.workers.dev' + u.pathname + u.search, {
      method: req.method, headers, ...(body.length ? {body} : {}),
      cf: {colo: 'LHR', httpProtocol: 'HTTP/2', tlsVersion: 'TLSv1.3'}, redirect: 'manual',
    });
    res.writeHead(r.status, {...Object.fromEntries(r.headers), 'set-cookie': r.headers.getSetCookie()});
    res.end(Buffer.from(await r.arrayBuffer()));
  } catch (e) { console.error('HARNESS', e); json(res, 500, {error: 'harness'}); }
});
await new Promise(r => server.listen(PORT, '127.0.0.1', r));
console.log('READY ' + PORT);
const stop = async () => { server.close(); await mf.dispose(); process.exit(0); };
process.on('SIGINT', stop); process.on('SIGTERM', stop);
