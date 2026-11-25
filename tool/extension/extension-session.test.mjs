import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';

const src = await readFile(new URL('./extension-session.js', import.meta.url), 'utf8');
function rig() {
  let now = 0, seq = 0; const timers = new Map(); const sockets = []; const events = []; const sent = [];
  const scope = {
    chrome: { runtime: { sendMessage: async m => { sent.push(m.type); if (m.type === 'status') return { ok: true, value: 'signed-in' }; if (m.type === 'ticket') return { ok: true, value: { ticket: 't' + sent.length, url: 'wss://x/' } }; return { ok: true, value: { signedOut: false, validMs: 1000 } }; } } },
    setTimeout: (f, ms) => { const id = ++seq; timers.set(id, { f, at: now + ms, ms }); return id; },
    clearTimeout: id => timers.delete(id),
    Date: { now: () => now },
    Math: Object.assign(Object.create(Math), { random: () => 0 }),
    WebSocket: class { constructor() { sockets.push(this); } close() {} },
  };
  vm.createContext(scope); vm.runInContext(src, scope);
  const advance = async ms => { const end = now + ms; for (;;) { const due = [...timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0]; if (!due) break; now = due[1].at; timers.delete(due[0]); await due[1].f(); await new Promise(r => setImmediate(r)); } now = end; };
  const flush = () => new Promise(r => setImmediate(r));
  return { s: scope.OTPandaSession, sockets, events, advance, flush, sent, timers };
}
const start = async r => { await r.s.ready; const stop = r.s.realtimeSubscribe(e => r.events.push(e)); await r.flush(); return stop; };

test('4429 close waits at least 60s before the next ticket', async () => {
  const r = rig(); await start(r);
  assert.equal(r.sockets.length, 1);
  r.sockets[0].onopen(); await r.sent.length;
  const before = r.sent.filter(x => x === 'ticket').length;
  await r.sockets[0].onclose({ code: 4429 }); await r.flush();
  await r.advance(59000);
  assert.equal(r.sent.filter(x => x === 'ticket').length, before);
  await r.advance(2000);
  assert.equal(r.sent.filter(x => x === 'ticket').length, before + 1);
  assert.ok(r.events.includes('connection-lost'));
});

test('attempt counter resets only after 30s stable; early close keeps growing backoff', async () => {
  const r = rig(); await start(r);
  const tickets = () => r.sent.filter(x => x === 'ticket').length;
  // fail 3 times via close after 5s open: backoff keeps growing (random=0 => base/2)
  const waits = [];
  for (let i = 0; i < 3; i++) {
    const sock = r.sockets[r.sockets.length - 1]; sock.onopen(); await r.advance(5000);
    await sock.onclose({ code: 1006 }); await r.flush();
    const t = [...r.timers.values()].map(x => x.ms); waits.push(Math.max(...t));
    await r.advance(Math.max(...t) + 1); await r.flush();
  }
  assert.deepEqual(waits, [2500, 5000, 10000]);
  // now stay open 30s: attempt resets, next failure waits the minimum again
  const sock = r.sockets[r.sockets.length - 1]; sock.onopen(); await r.advance(30001);
  await sock.onclose({ code: 1006 }); await r.flush();
  assert.equal(Math.max(...[...r.timers.values()].map(x => x.ms)), 2500);
  assert.ok(tickets() >= 4);
});

test('connect event only after 2s stable; accept-then-close emits none', async () => {
  const r = rig(); await start(r);
  r.sockets[0].onopen(); await r.advance(1500);
  await r.sockets[0].onclose({ code: 1006 });
  await r.advance(1000);
  assert.ok(!r.events.includes('connect'));
  await r.advance(10000); const s2 = r.sockets[r.sockets.length - 1]; assert.notEqual(s2, r.sockets[0]);
  s2.onopen(); await r.advance(2001);
  assert.ok(r.events.includes('connect'));
});

test('repeated 4408 within 30s uses normal backoff and no forced renew', async () => {
  const r = rig(); await start(r);
  const maints = () => r.sent.filter(x => x === 'maintain').length;
  await r.sockets[0].onclose({ code: 4408 }); await r.flush();
  assert.equal(maints(), 1);
  await r.advance(2100);
  const s2 = r.sockets[r.sockets.length - 1]; assert.notEqual(s2, r.sockets[0]);
  await s2.onclose({ code: 4408 }); await r.flush();
  assert.equal(maints(), 1, 'second 4408 inside 30s must not force a renew');
  assert.ok(Math.max(...[...r.timers.values()].map(x => x.ms)) >= 2500);
  // outside 30s the quick path returns
  await r.advance(40000); const s3 = r.sockets[r.sockets.length - 1];
  await s3.onclose({ code: 4408 }); await r.flush();
  assert.equal(maints(), 2);
});
