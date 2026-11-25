// Contract stand-in for the extension auth API, for real-browser tests only. It is NOT the real API:
// it implements the documented begin/exchange/challenge/renew/logout/read behaviour with real PKCE and real
// ECDSA verification so browser behaviour (identity window, CORS, IndexedDB key, restarts) is exercised.
import https from 'node:https';
import { readFileSync } from 'node:fs';
import { webcrypto as wc, randomBytes, createHash } from 'node:crypto';

const PAGES = 'otpanda.github.io', API_HOST = 'otpanda-api.abrahammurciano.workers.dev';
const b64u = b => Buffer.from(b).toString('base64url');
const opaque = () => b64u(randomBytes(32));
const token = () => 'otpda_' + b64u(randomBytes(42)).slice(0, 55);
export async function startStandin({ pagesRoot, cert, key, ttlMs = 300000, redirects, real }) {
  const st = { log: [], pinnedOrigin: undefined, mode: { challenge: 'ok', renew: 'ok', read: 'ok' }, devices: new Map(), codes: new Map(), nonces: new Map(), tokens: new Map(), webCodes: new Map(), exchanges: 0, ttlMs, redirects };
  st.real = real;
  st.revokeAll = () => (real ? real.revokeAll() : [...st.devices.values()].forEach(d => { d.revoked = true; }));
  st.lastRevoked = () => (real ? real.revoked().at(-1)?.revoked_at != null : [...st.devices.values()].at(-1)?.revoked === true);
  const send = (res, status, body, headers = {}) => { res.writeHead(status, { 'Cache-Control': 'no-store', ...(body === undefined || status === 204 ? {} : { 'Content-Type': 'application/json' }), ...headers }); res.end(status === 204 || body === undefined ? undefined : JSON.stringify(body)); };
  const readBody = req => new Promise(r => { let s = ''; req.on('data', d => (s += d)); req.on('end', () => r(s)); });
  const strict = (text, keys) => { try { const j = JSON.parse(text); return j && typeof j === 'object' && Object.keys(j).sort().join(',') === keys ? j : undefined; } catch { return undefined; } };
  const originOk = o => o === undefined || o === st.pinnedOrigin;
  const cors = { 'Access-Control-Allow-Origin': 'https://' + PAGES, 'Access-Control-Allow-Headers': 'authorization,content-type', 'Access-Control-Allow-Methods': 'POST,GET', Vary: 'Origin' };
  const bearer = req => { const m = /^Bearer (otpda_[A-Za-z0-9_-]{55})$/.exec(req.headers.authorization ?? ''); return m && st.tokens.get(m[1]); };
  const mint = (kind, deviceId) => { const t = token(), exp = Date.now() + st.ttlMs; st.tokens.set(t, { kind, deviceId, exp }); return { access: t, access_expires_at: exp }; };
  const server = https.createServer({ cert: readFileSync(cert), key: readFileSync(key) }, async (req, res) => {
    const host = (req.headers.host ?? '').split(':')[0], u = new URL(req.url, 'https://' + host), p = u.pathname;
    const done = status => st.log.push({ host, method: req.method, path: p, origin: req.headers.origin, status });
    res.on('finish', () => done(res.statusCode));
    if (host === PAGES) return send(res, 404, {});
    if (host !== API_HOST) return send(res, 404, {});
    const body = req.method === 'POST' ? await readBody(req) : '';
    if (req.method === 'OPTIONS') return req.headers.origin === 'https://' + PAGES && ['/auth/extension/begin', '/auth/exchange'].includes(p) ? send(res, 204, undefined, cors) : send(res, 404, {});
    if (p === '/auth/restore') {
      const code = token(); st.webCodes.set(code, { challenge: u.searchParams.get('challenge') });
      res.writeHead(302, { Location: u.searchParams.get('redirect_uri') + '#' + new URLSearchParams({ code, state: u.searchParams.get('state') }) }); return res.end();
    }
    if (p === '/auth/exchange') {
      const j = JSON.parse(body), w = st.webCodes.get(j.code); st.webCodes.delete(j.code);
      if (!w || createHash('sha256').update(j.verifier).digest('base64url') !== w.challenge) return send(res, 401, { error: 'invalid_grant' }, cors);
      if (real) return send(res, 200, { access: real.webAccess, accessExpiresAt: Date.now() + 300000 }, cors);
      const t = mint('web'); return send(res, 200, { access: t.access, accessExpiresAt: t.access_expires_at }, cors);
    }
    if (real && (p.startsWith('/auth/extension/') || p.startsWith('/v1/manage/'))) {
      const inject = p.endsWith('/challenge') ? st.mode.challenge : p.endsWith('/renew') ? st.mode.renew : p.startsWith('/v1/') ? st.mode.read : 'ok';
      if (inject !== 'ok') return send(res, Number(inject), { error: 'x' });
      const h = {}; for (const [k, v] of Object.entries(req.headers)) if (!['host', 'connection', 'content-length'].includes(k)) h[k] = v;
      const rr = await real.fetch(new Request('https://' + API_HOST + req.url, { method: req.method, headers: h, body: req.method === 'GET' || req.method === 'HEAD' ? undefined : body }), { clientAddress: '127.0.0.1' });
      const text = await rr.text(); const oh = {}; rr.headers.forEach((v, k) => { oh[k] = v; });
      if (p.endsWith('/exchange') && rr.status === 200) st.exchanges++;
      res.writeHead(rr.status, oh); return res.end(text);
    }
    if (p === '/auth/extension/begin') {
      if (req.headers.origin !== 'https://' + PAGES) return send(res, 403, { error: 'forbidden' });
      const who = bearer(req); if (!who || who.kind !== 'web') return send(res, 401, { error: 'unauthorized' }, cors);
      const d = strict(body, 'challenge,confirm,redirect,state');
      if (!d || d.confirm !== true || !/^[A-Za-z0-9_-]{43}$/.test(d.challenge) || !/^[A-Za-z0-9_-]{43}$/.test(d.state) || !Object.hasOwn(st.redirects, d.redirect)) return send(res, 400, { error: 'invalid_request' }, cors);
      const code = token(); st.codes.set(code, { challenge: d.challenge, redirect: d.redirect, exp: Date.now() + 60000 });
      const target = new URL(st.redirects[d.redirect]); target.hash = new URLSearchParams({ code, state: d.state }).toString();
      return send(res, 200, { redirect: target.href, expires_at: Date.now() + 60000 }, cors);
    }
    if (p.startsWith('/auth/extension/')) {
      if (!originOk(req.headers.origin) || req.method !== 'POST') return send(res, 403, { error: 'forbidden' });
      if (p === '/auth/extension/exchange') {
        const d = strict(body, 'code,redirect,renewal_key,verifier');
        if (!d || !Object.hasOwn(st.redirects, d.redirect) || Buffer.from(d.renewal_key, 'base64url').length !== 65) return send(res, 400, { error: 'invalid_request' });
        const c = st.codes.get(d.code); st.codes.delete(d.code);
        if (!c || c.exp < Date.now() || c.redirect !== d.redirect || createHash('sha256').update(d.verifier).digest('base64url') !== c.challenge) return send(res, 401, { error: 'invalid_grant' });
        const deviceId = 'dev_' + b64u(randomBytes(12)); st.devices.set(deviceId, { pub: d.renewal_key, revoked: false });
        st.exchanges++; return send(res, 200, { device_id: deviceId, ...mint('extension', deviceId) });
      }
      if (p === '/auth/extension/challenge') {
        if (st.mode.challenge !== 'ok') return send(res, Number(st.mode.challenge), { error: 'x' });
        const d = strict(body, 'device_id,purpose'), dev = d && st.devices.get(d.device_id);
        if (!dev || dev.revoked) return send(res, 401, { error: 'invalid_grant' });
        const nonce = opaque(), exp = Date.now() + 60000; st.nonces.set(nonce, { deviceId: d.device_id, purpose: d.purpose, exp });
        return send(res, 200, { device_id: d.device_id, nonce, expires_at: exp });
      }
      if (p === '/auth/extension/renew' || p === '/auth/extension/logout') {
        if (p.endsWith('renew') && st.mode.renew !== 'ok') return send(res, Number(st.mode.renew), { error: 'x' });
        if (p.endsWith('logout') && req.headers.authorization) { const w = bearer(req); if (!w || w.kind !== 'extension' || body !== '') return send(res, 401, { error: 'invalid_grant' }); st.devices.get(w.deviceId).revoked = true; return send(res, 204); }
        const d = strict(body, 'device_id,expires_at,nonce,signature'), dev = d && st.devices.get(d.device_id), n = d && st.nonces.get(d.nonce);
        const purpose = p.endsWith('renew') ? 'renew' : 'logout';
        if (!dev || dev.revoked || !n || n.deviceId !== d.device_id || n.purpose !== purpose || n.exp < Date.now() || d.expires_at !== n.exp || !/^[A-Za-z0-9_-]{86}$/.test(d.signature)) return send(res, 401, { error: 'invalid_grant' });
        st.nonces.delete(d.nonce);
        const msg = ['otpanda-extension-v1', 'POST ' + p, d.device_id, d.nonce, String(d.expires_at)].join('\n');
        const k = await wc.subtle.importKey('raw', Buffer.from(dev.pub, 'base64url'), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
        if (!await wc.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, k, Buffer.from(d.signature, 'base64url'), Buffer.from(msg))) return send(res, 401, { error: 'invalid_grant' });
        if (purpose === 'logout') { dev.revoked = true; return send(res, 204); }
        return send(res, 200, mint('extension', d.device_id));
      }
      return send(res, 404, {});
    }
    if (p.startsWith('/v1/manage/') && req.method === 'GET') {
      const w = bearer(req);
      if (!w || w.kind !== 'extension' || w.exp < Date.now() || st.devices.get(w.deviceId)?.revoked) return send(res, 401, { error: 'unauthorized' });
      if (st.mode.read !== 'ok') return send(res, Number(st.mode.read), {});
      return send(res, 200, { ownerId: 'o_e2e', path: p + u.search });
    }
    return send(res, 404, {});
  });
  // Pages: serve the real bootstrap scripts plus a tiny page that shows the confirm button when signed in with an intent.
  const orig = server.listeners('request')[0]; server.removeAllListeners('request');
  const { readFile } = await import('node:fs/promises');
  server.on('request', async (req, res) => {
    const host = (req.headers.host ?? '').split(':')[0], p = new URL(req.url, 'https://x').pathname;
    if (host === PAGES && p.startsWith('/app/')) {
      st.log.push({ host, method: req.method, path: p });
      const name = p.slice(5) || 'index.html';
      if (name === 'index.html') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end('<!doctype html><html><head><base href="/app/"></head><body><div id="s">loading</div><script src="extension-launch-intent.js"></script><script src="session-bootstrap.js"></script><script src="stub-ui.js"></script></body></html>'); }
      if (['extension-launch-intent.js', 'session-bootstrap.js'].includes(name)) { res.writeHead(200, { 'Content-Type': 'text/javascript' }); return res.end(await readFile(pagesRoot + '/' + name)); }
      if (name === 'cookie-probe.html') { st.cookieSeen = st.cookieSeen ?? []; st.cookieSeen.push(/probe=1/.test(req.headers.cookie ?? '')); res.writeHead(200, { 'Content-Type': 'text/html', 'Set-Cookie': 'probe=1; Path=/; Secure; SameSite=None' }); return res.end('<!doctype html><title>probe</title>cookie probe'); }
      if (name === 'stub-ui.js') { res.writeHead(200, { 'Content-Type': 'text/javascript' }); return res.end(`(async()=>{await OTPandaSession.ready;const s=document.getElementById('s');const st=OTPandaSession.status();s.textContent=st+(OTPandaSession.extensionIntent()?' intent':'');if(st==='restored'&&OTPandaSession.extensionIntent()){const b=document.createElement('button');b.id='connect';b.textContent='Connect browser extension';b.onclick=async()=>{s.textContent='result:'+await OTPandaSession.extensionConnect();};document.body.append(b);}})();`); }
      res.writeHead(404); return res.end();
    }
    return orig(req, res);
  });
  // Synthetic realtime (the real API has no extension route yet): ticket mint + minimal RFC 6455 hub. Test fixture only.
  st.rt = { tickets: new Map(), sockets: new Set(), mints: 0, upgrades: [], mode: 'ok', mintStatus: 200 };
  const prev = server.listeners('request')[0]; server.removeAllListeners('request');
  server.on('request', async (req, res) => {
    const host = (req.headers.host ?? '').split(':')[0], p = new URL(req.url, 'https://x').pathname;
    if (host === API_HOST && p === '/auth/extension/realtime/ticket' && req.method === 'POST') {
      st.rt.mints++; (st.rt.times ??= []).push(Date.now() % 100000);
      const bearer = (req.headers.authorization ?? '').replace(/^Bearer /, '');
      if (!(st.tokens.has(bearer) || (real && /^otpda_/.test(bearer))) || st.rt.mintStatus !== 200) { res.writeHead(st.rt.mintStatus === 200 ? 401 : st.rt.mintStatus, { 'Content-Type': 'application/json' }); return res.end('{}'); }
      const t = 'rt1.' + b64u(randomBytes(12)) + '.' + b64u(randomBytes(32)); st.rt.tickets.set(t, Date.now() + 30000);
      res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ ticket: t, expiresAt: Date.now() + 30000, closeAt: Date.now() + 300000, serverTime: Date.now() }));
    }
    return prev(req, res);
  });
  const frame = (op, payload) => { const b = Buffer.from(payload); return Buffer.concat([Buffer.from([0x80 | op, b.length]), b]); };
  server.on('upgrade', (req, sock) => {
    const host = (req.headers.host ?? '').split(':')[0], offered = (req.headers['sec-websocket-protocol'] ?? '').split(',').map(v => v.trim());
    st.rt.upgrades.push({ origin: req.headers.origin, offered: offered.length, t: Date.now() % 100000 });
    const ok = host === API_HOST && req.url === '/auth/extension/realtime' && offered.length === 2 && offered[0] === 'otpanda.v1' && st.rt.tickets.delete(offered[1]) && /^chrome-extension:\/\//.test(req.headers.origin ?? '') && st.rt.mode === 'ok';
    if (!ok) { sock.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return; }
    const acc = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    sock.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + acc + '\r\nSec-WebSocket-Protocol: otpanda.v1\r\n\r\n');
    if (st.rt.flap) { sock.end(frame(8, Buffer.from([0x03, 0xf3]))); return; }
    st.rt.sockets.add(sock); sock.on('close', () => st.rt.sockets.delete(sock)); sock.on('error', () => {}); sock.on('data', d => { if ((d[0] & 0x0f) === 8) sock.end(frame(8, Buffer.alloc(2))); });
  });
  st.rt.hint = (text = '{"v":1,"t":"changed"}') => { for (const s of st.rt.sockets) s.write(frame(1, text)); };
  st.rt.close = code => { (st.rt.times ??= []).push('close' + code + '@' + (Date.now() % 100000)); for (const s of [...st.rt.sockets]) { const c = Buffer.alloc(2); c.writeUInt16BE(code); s.end(frame(8, c)); } };
  await new Promise(r => server.listen(8443, '127.0.0.1', r));
  st.close = () => new Promise(r => server.close(r));
  return st;
}
