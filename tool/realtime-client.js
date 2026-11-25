/* Realtime change-hint client. Classic script, loaded before session-bootstrap.js.
 * Memory only: no ticket, token or message is logged or stored. The stream is a
 * content-free hint; every change is re-read through the normal authorized GETs.
 * Contract source: api src/realtime-http.js and src/realtime-hub.js. */
(() => {
  'use strict';
  const SUBPROTOCOL = 'otpanda.v1';
  const CLOSE_REVOKED = 4401, CLOSE_EXPIRED = 4408, CLOSE_REPLACED = 4429;
  // Engineering defaults, not server values.
  const DEFAULTS = Object.freeze({
    hiddenPauseMs: 60000, coalesceGapMs: 1000, backoffBaseMs: 1000, backoffMaxMs: 60000,
    stableOpenMs: 30000, replaceBackoffMs: 60000, replaceCap: 3, replaceWindowMs: 600000,
    degradedMs: 60000, lostAfterMs: 120000, slowRetryMs: 120000, unknownFailureCap: 3, ticketTimeoutMs: 15000, retryAfterCapMs: 300000,
    openTimeoutMs: 15000, ticketBodyMax: 2048, waitingBaseMs: 1000, waitingMaxMs: 15000, fastReconnectMs: 1000,
  });
  function create(options) {
    const o = options || {};
    const cfg = { ...DEFAULTS, ...(o.tuning || {}) };
    const api = String(o.api || '').replace(/\/+$/, '');
    if (!/^https:\/\/[^/?#]+$/.test(api)) throw Error('HTTPS API origin required');
    const wsUrl = 'wss://' + api.slice(8) + '/auth/realtime';
    const ticketUrl = api + '/auth/realtime/ticket';
    const fetchImpl = o.fetch, WS = o.WebSocket;
    const setT = o.setTimeout || globalThis.setTimeout, clearT = o.clearTimeout || globalThis.clearTimeout;
    const now = o.now || Date.now, rand = o.random || Math.random;
    const doc = o.document, win = o.window;
    // Callbacks. getAccess() resolves a valid access token or undefined; it must not navigate.
    // onChanged(reason) re-reads data and may return a promise. onUnauthorized() runs the normal
    // renew/restore path. epoch() changes on sign-out so late results are dropped.
    const getAccess = o.getAccess, onChanged = o.onChanged || (() => {}), onUnauthorized = o.onUnauthorized || (async () => {});
    const epochOf = o.epoch || (() => 0), onState = o.onState || (() => {}), onConnection = o.onConnection || (() => {});
    let state = 'stopped', running = false, ws, myEpoch = 0, runId = 0;
    let timer, hiddenTimer, openedAt = 0, failures = 0, unknownFailures = 0, auth401 = 0, replaced = [];
    let ticketAbort, openTimer, waits = 0, refreshing = false, trailing = false, lastRefreshAt = -Infinity, gapTimer;
    // User-facing connection summary, separate from the transport state. 'ok' shows nothing; 'lost' means recovery has failed persistently
    // (or can never succeed on this page load); 'ended' means the session ended (ticket 401 twice) and the session flow owns it.
    let conn = Object.freeze({ status: 'ok', reason: undefined, retrying: true, since: now() }), failSince, lostTimer, stableTimer, signedIn = false;
    const setConn = (status, reason, retrying) => {
      if (conn.status === status && conn.reason === reason && conn.retrying === retrying) return;
      const changed = conn.status !== status || conn.reason !== reason;
      conn = Object.freeze({ status, reason, retrying, since: changed ? now() : conn.since });
      if (changed) { try { onConnection(conn); } catch {} }
    };
    const clearLost = () => { if (lostTimer !== undefined) { clearT(lostTimer); lostTimer = undefined; } };
    // Stop counting failure time (hidden, offline, signed out, stopped). Does not clear an already raised 'lost'.
    const resetClock = () => { failSince = undefined; clearLost(); if (stableTimer !== undefined) { clearT(stableTimer); stableTimer = undefined; } };
    const raiseLost = (reason, retrying = true) => { clearLost(); if (conn.status === 'ended') return; setConn('lost', reason, retrying); };
    // Only visible, online, signed-in failure time counts: callers reach this from real failed attempts, and pause/hidden/waiting reset the clock.
    const markFailure = reason => {
      // The clock only starts or advances for visible, online, signed-in failures. A late failure from an attempt that began before the tab
      // was hidden, went offline or signed out must not count.
      if (!running || !signedIn || !visible() || !online()) return;
      if (stableTimer !== undefined) { clearT(stableTimer); stableTimer = undefined; }
      if (failSince === undefined) failSince = now();
      if (conn.status === 'lost') return;
      if (now() - failSince >= cfg.lostAfterMs) return raiseLost(reason || 'unreachable');
      if (lostTimer === undefined) lostTimer = setT(() => { lostTimer = undefined; if (running && failSince !== undefined && visible() && online()) raiseLost(reason || 'unreachable'); }, Math.max(0, failSince + cfg.lostAfterMs - now()));
    };
    const set = s => { if (state !== s) { state = s; try { onState(s); } catch {} } };
    const visible = () => !doc || doc.visibilityState !== 'hidden';
    const online = () => !win || win.navigator?.onLine !== false;
    const clearTimer = () => { if (timer !== undefined) { clearT(timer); timer = undefined; } };
    const abortTicket = () => { const a = ticketAbort; ticketAbort = undefined; try { a?.abort(); } catch {} };
    const closeSocket = (code = 1000) => {
      abortTicket();
      if (openTimer !== undefined) { clearT(openTimer); openTimer = undefined; }
      const s = ws; ws = undefined;
      if (s) { s.onopen = s.onmessage = s.onclose = s.onerror = null; try { s.close(code, ''); } catch {} }
    };
    const stale = id => id !== runId || epochOf() !== myEpoch;
    // Equal jitter: never below half the exponential step, so no tight loop even with an unlucky random.
    const jitterBackoff = n => { const step = Math.min(cfg.backoffMaxMs, cfg.backoffBaseMs * 2 ** Math.min(n, 16)); return step / 2 + rand() * step / 2; };
    const schedule = (ms, reason) => { clearTimer(); const id = runId; timer = setT(() => { timer = undefined; if (id === runId) connect(); }, Math.max(0, ms)); void reason; };
    const retryAfterMs = res => {
      const v = res.headers?.get?.('retry-after');
      if (typeof v !== 'string' || !/^[0-9]{1,6}$/.test(v)) return 0;
      return Math.min(cfg.retryAfterCapMs, Number(v) * 1000);
    };
    // Coalesce: one refresh in flight, one trailing, at least coalesceGapMs between starts.
    const requestRefresh = reason => {
      if (refreshing) { trailing = true; return; }
      const wait = lastRefreshAt + cfg.coalesceGapMs - now();
      if (wait > 0) { trailing = true; if (gapTimer === undefined) { const id = runId; gapTimer = setT(() => { gapTimer = undefined; if (id === runId && trailing && !refreshing) { trailing = false; requestRefresh('changed'); } }, wait); } return; }
      refreshing = true; lastRefreshAt = now(); const id = runId;
      Promise.resolve().then(() => onChanged(reason)).catch(() => {}).finally(() => {
        refreshing = false;
        if (id === runId && trailing) { trailing = false; requestRefresh('changed'); }
      });
    };
    const degrade = () => {
      closeSocket(); set('degraded'); unknownFailures = 0; markFailure('unreachable'); schedule(cfg.degradedMs, 'degraded');
    };
    const slowLost = (reason, floorMs) => {
      closeSocket(); resetClock(); failures++; set('degraded'); raiseLost(reason, true);
      schedule(Math.min(cfg.retryAfterCapMs, Math.max(floorMs, cfg.slowRetryMs / 2 + rand() * cfg.slowRetryMs / 2)), 'slow');
    };
    const backoff = (extraMs = 0) => {
      failures++; set('backoff'); markFailure('unreachable');
      schedule(Math.max(extraMs ? extraMs + rand() * 1000 : 0, jitterBackoff(failures - 1)), 'backoff');
    };
    // Bound bytes as they arrive; a streamed oversize or advertised-oversize body is refused and cancelled.
    async function boundedText(res, limit, deadline) {
      const adv = res.headers?.get?.('content-length');
      if (adv !== null && adv !== undefined && (!/^[0-9]+$/.test(adv) || Number(adv) > limit)) throw Error('too large');
      if (res.body?.getReader) {
        const reader = res.body.getReader(), dec = new TextDecoder('utf-8', { fatal: true }); let size = 0, text = '';
        try {
          for (;;) { const { done, value } = await (deadline ? Promise.race([reader.read(), deadline]) : reader.read()); if (done) break; size += value.byteLength; if (size > limit) { try { await reader.cancel(); } catch {} throw Error('too large'); } text += dec.decode(value, { stream: true }); }
          return text + dec.decode();
        } catch (e) { try { await Promise.race([reader.cancel(), new Promise(r => setT(r, 0))]); } catch {} throw e; }
        finally { try { reader.releaseLock(); } catch {} }
      }
      const text = await (deadline ? Promise.race([res.text(), deadline]) : res.text()); if (typeof text !== 'string' || text.length > limit) throw Error('too large'); return text;
    }
    async function connect() {
      if (!running || state === 'connecting' || state === 'open') return;
      if (!visible() || !online()) { set('paused'); return; }
      const id = ++runId; myEpoch = epochOf(); set('connecting');
      let token;
      try { token = await getAccess(); } catch { token = undefined; }
      if (stale(id)) return;
      if (!token) {
        // Transient: not restored yet, or signed out with listeners kept. Local check only, no network. Retry with backoff.
        waits++; signedIn = false; resetClock(); if (conn.status !== 'ended') setConn('ok', undefined, true); set('waiting');
        const step = Math.min(cfg.waitingMaxMs, cfg.waitingBaseMs * 2 ** Math.min(waits - 1, 16));
        schedule(step / 2 + rand() * step / 2, 'waiting'); return;
      }
      waits = 0; signedIn = true;
      let res, body;
      const abort = typeof AbortController === 'function' ? new AbortController() : undefined;
      ticketAbort = abort;
      let tt;
      // One deadline covers the request, the headers and the body read. Expiry aborts the fetch and cancels the reader.
      const deadline = new Promise((_, rej) => { tt = setT(() => { try { abort?.abort(); } catch {} rej(Error('timeout')); }, cfg.ticketTimeoutMs); });
      deadline.catch(() => {});
      try {
        try {
          res = await Promise.race([
            fetchImpl(ticketUrl, { method: 'POST', credentials: 'omit', cache: 'no-store', redirect: 'error', headers: { Authorization: 'Bearer ' + token }, ...(abort ? { signal: abort.signal } : {}) }),
            deadline,
          ]);
        } catch { if (stale(id)) return; return backoff(); }
        if (stale(id)) return;
        if (res.status === 401) {
          // Never retry a ticket on 401. One renew through the normal path; a second 401 ends this run.
          auth401++;
          if (auth401 > 1) { running = false; signedIn = false; resetClock(); setConn('ended', 'auth', false); set('stopped'); return; }
          try { await onUnauthorized(); } catch {}
          if (stale(id)) return;
          return backoff();
        }
        // 404 means realtime is off server-side, 400/403/405 are client-contract errors. Neither is proven permanent for the page's life (a deploy can
        // fix it), so: lost at once, then slow capped jittered retries. Retry-After is a floor.
        if (res.status === 404) return slowLost('unavailable', retryAfterMs(res));
        // Other 5xx and 408 are transient server failures: bounded backoff, never a permanent stop.
        if (res.status >= 500 && res.status !== 503 || res.status === 408) return backoff();
        if (res.status === 429 || res.status === 503) return backoff(retryAfterMs(res) || (res.status === 429 ? 30000 : 0));
        if (res.status !== 200) {
          // 400, 403, 405 are client bugs: do not hammer.
          return slowLost('rejected', retryAfterMs(res));
        }
        try { body = JSON.parse(await boundedText(res, cfg.ticketBodyMax, deadline)); } catch { if (stale(id)) return; return backoff(); }
      } finally { if (tt !== undefined) clearT(tt); if (ticketAbort === abort) ticketAbort = undefined; }
      if (stale(id)) return;
      if (!body || typeof body.ticket !== 'string' || !/^rt1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{43}$/.test(body.ticket)) return backoff();
      auth401 = 0;
      let sock;
      try { sock = new WS(wsUrl, [SUBPROTOCOL, body.ticket]); } catch { return backoff(); }
      ws = sock; let opened = false;
      openTimer = setT(() => { if (!opened && ws === sock && !stale(id)) { sock.onclose = null; closeSocket(1000); unknownFailures++; if (unknownFailures >= cfg.unknownFailureCap) degrade(); else backoff(); } }, cfg.openTimeoutMs);
      sock.onopen = () => {
        if (stale(id) || ws !== sock) { try { sock.close(1000, ''); } catch {} return; }
        if (sock.protocol !== SUBPROTOCOL) { closeSocket(1008); return backoff(); }
        opened = true; if (openTimer !== undefined) { clearT(openTimer); openTimer = undefined; } openedAt = now(); unknownFailures = 0; clearLost(); setConn('ok', undefined, true); if (stableTimer !== undefined) clearT(stableTimer); stableTimer = setT(() => { stableTimer = undefined; failSince = undefined; }, cfg.stableOpenMs); set('open');
        requestRefresh('connect');
      };
      sock.onmessage = ev => {
        if (stale(id) || ws !== sock || typeof ev.data !== 'string' || ev.data.length > 256) return;
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        if (m && m.v === 1 && m.t === 'changed') requestRefresh('changed');
      };
      sock.onerror = () => {};
      sock.onclose = ev => {
        if (stale(id) || ws !== sock) return;
        ws = undefined; if (openTimer !== undefined) { clearT(openTimer); openTimer = undefined; } const code = ev?.code;
        const stable = opened && now() - openedAt >= cfg.stableOpenMs;
        if (stable) failures = 0;
        if (!opened) { unknownFailures++; if (unknownFailures >= cfg.unknownFailureCap) return degrade(); return backoff(); }
        if (code === CLOSE_REVOKED) {
          // No immediate reconnect. The normal session check decides (renew once or sign out); a
          // still-valid local session retries with backoff and a second ticket 401 ends the run.
          set('backoff'); const rid = runId;
          Promise.resolve().then(() => onUnauthorized()).catch(() => {}).then(() => { if (rid === runId && running) backoff(); });
          return;
        }
        if (code === CLOSE_EXPIRED || code === 1006 || code === 1001) {
          // Only a stable connection reconnects fast (access reached its close time). An early close of any
          // kind counts as a failure and uses exponential backoff, so a flapping server cannot be hammered.
          if (stable) { set('backoff'); schedule(rand() * cfg.fastReconnectMs, 'expired'); return; }
          return backoff();
        }
        if (code === CLOSE_REPLACED) {
          const t = now(); replaced = replaced.filter(x => t - x < cfg.replaceWindowMs); replaced.push(t);
          if (replaced.length >= cfg.replaceCap) { replaced = []; degrade(); raiseLost('replaced'); return; }
          set('backoff'); schedule(cfg.replaceBackoffMs + rand() * 1000, 'replaced'); return;
        }
        if (code === 1008) return slowLost('rejected', 0);
        backoff();
      };
    }
    const pause = () => {
      if (!running) return; clearTimer(); resetClock(); runId++; closeSocket(1000); set('paused');
    };
    const resume = (reset = false) => {
      if (!running || !visible() || !online()) return;
      if (state === 'open' || state === 'connecting') return;
      if (reset) { failures = 0; unknownFailures = 0; }
      if (state === 'degraded' || state === 'backoff') { if (!reset) return; }
      clearTimer(); connect();
    };
    const onVisibility = () => {
      if (!doc) return;
      if (doc.visibilityState === 'hidden') {
        resetClock();
        if (hiddenTimer === undefined) hiddenTimer = setT(() => { hiddenTimer = undefined; if (!visible()) pause(); }, cfg.hiddenPauseMs);
      } else {
        if (hiddenTimer !== undefined) { clearT(hiddenTimer); hiddenTimer = undefined; }
        if (state === 'paused') resume(true);
      }
    };
    const onOffline = () => { if (running) pause(); };
    const onOnline = () => { if (state === 'paused') resume(true); else if (running && state === 'backoff') resume(true); };
    const onPageShow = e => { if (e?.persisted && running) { runId++; clearTimer(); resetClock(); closeSocket(1000); set('paused'); resume(true); } };
    doc?.addEventListener?.('visibilitychange', onVisibility);
    win?.addEventListener?.('offline', onOffline);
    win?.addEventListener?.('online', onOnline);
    win?.addEventListener?.('pageshow', onPageShow);
    return Object.freeze({
      start() { if (running) return; running = true; resetClock(); setConn('ok', undefined, true); failures = 0; unknownFailures = 0; auth401 = 0; replaced = []; connect(); },
      // Sign-out, clear or disposal: close, cancel every timer, drop late results.
      stop() { running = false; signedIn = false; runId++; clearTimer(); resetClock(); if (conn.status !== 'ended') setConn('ok', undefined, true); if (hiddenTimer !== undefined) { clearT(hiddenTimer); hiddenTimer = undefined; } if (gapTimer !== undefined) { clearT(gapTimer); gapTimer = undefined; } trailing = false; closeSocket(1000); set('stopped'); },
      // Sign-out with listeners kept: close and drop late work, but keep the intent to run so a later restore
      // reconnects. Only a local access check runs while waiting (no network).
      suspend() { if (!running) return; signedIn = false; runId++; clearTimer(); resetClock(); setConn('ok', undefined, true); if (gapTimer !== undefined) { clearT(gapTimer); gapTimer = undefined; } trailing = false; refreshing = false; closeSocket(1000); failures = 0; unknownFailures = 0; auth401 = 0; waits = 0; set('waiting'); schedule(cfg.waitingBaseMs / 2 + rand() * cfg.waitingBaseMs / 2, 'waiting'); },
      // Sign-in or restore completed: leave the waiting state now instead of at the next backoff step.
      nudge() { if (running && state === 'waiting') { clearTimer(); waits = 0; connect(); } },
      state: () => state,
      connection: () => conn,
      dispose() { this.stop(); doc?.removeEventListener?.('visibilitychange', onVisibility); win?.removeEventListener?.('offline', onOffline); win?.removeEventListener?.('online', onOnline); win?.removeEventListener?.('pageshow', onPageShow); },
    });
  }
  const factory = Object.freeze({ create, DEFAULTS });
  if (typeof module !== 'undefined' && module.exports) module.exports = factory;
  else Object.defineProperty(globalThis, 'OTPandaRealtime', { value: factory });
})();
