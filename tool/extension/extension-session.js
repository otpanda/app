'use strict';
// Popup side of the sign-in bridge. It holds no key, record, verifier or bearer: every call is a message to the
// background worker. Reads are limited to the three GET routes the API gives an extension session; everything else
// is answered here as unsupported (503) with no message, no renew and no change of state.
(() => {
  const READ_PATHS = ['/v1/manage/entries', '/v1/manage/active-codes', '/v1/manage/entry/domains'];
  const unsupported = async () => ({ status: 503, body: JSON.stringify({ error: 'unsupported' }) });
  const send = async m => {
    const r = await chrome.runtime.sendMessage(m);
    if (!r || r.ok !== true) throw Error('unavailable');
    return r.value;
  };
  let status = 'idle', expires = 0;
  const map = s => (s === 'signed-in' ? 'restored' : s === 'signing-in' ? 'restoring' : 'idle');
  const ready = (async () => { try { status = map(await send({ type: 'status' })); } catch { status = 'idle'; } })();
  // The Flutter shell navigates through OTPandaNavigation (the web bootstrap provides it). In the popup the
  // route is plain in-memory state: no URL, no history, no storage.
  let route = 'codes';
  const listeners = new Set();
  Object.defineProperty(globalThis, 'OTPandaNavigation', {
    writable: false, configurable: false,
    value: Object.freeze({
      current: () => route,
      go: r => { if (typeof r !== 'string' || !/^[a-z0-9/_-]{1,64}$/.test(r)) return; route = r; for (const f of [...listeners]) { try { f(); } catch { /* listener errors stay local */ } } },
      listen: f => { if (typeof f === 'function') listeners.add(f); },
      unlisten: f => { listeners.delete(f); },
    }),
  });
  Object.defineProperty(globalThis, 'OTPandaSession', {
    writable: false, configurable: false,
    value: Object.freeze({
      ready,
      status: () => status,
      // Any sign-in entry opens the one identity window. The popup never sees what it returns.
      start: async () => {
        status = 'restoring';
        let r;
        try { r = await send({ type: 'signIn' }); } catch { status = 'idle'; throw Error('unavailable'); }
        status = r?.ok === true ? 'restored' : 'idle';
        if (!r?.ok) throw Error(r?.error ?? 'unavailable');
      },
      passkey: async () => { throw Error('unsupported'); },
      clear: () => {},
      logout: () => { status = 'idle'; send({ type: 'logout' }).catch(() => {}); },
      read: async path => {
        if (!READ_PATHS.includes(path)) return { status: 503, body: JSON.stringify({ error: 'unsupported' }) };
        if (status !== 'restored') return { status: 401, body: '{}' };
        const r = await send({ type: 'read', path });
        // Signed out only when the worker says its record is actually gone. A final 401 or a failure stays unavailable.
        if (r.signedOut === true) status = 'idle';
        return { status: r.status, body: r.body };
      },
      organize: unsupported,
      copied: unsupported,
      // The worker renews the bearer; the popup only mirrors how long it is good for (from the worker's own receipt clock).
      maintain: async () => {
        try {
          const r = await send({ type: 'maintain' });
          if (r.ok) expires = Date.now() + r.validMs; else if (r.signedOut === true) status = 'idle';
        } catch { /* unavailable: keep the last view */ }
      },
      accessExpiresAt: () => expires,
      // Features the popup does not offer. Each one is an explicit, harmless no-op or an honest refusal.
      // Popup-lifetime socket only: it exists while the popup is open and closes with it. The worker returns a one-use
      // ticket (never the bearer). Any failure backs off 5s to 5min with jitter. A closed socket never clears the
      // record: 4401 forces one signed renew through the worker, and only a definitive renew 401 signs out.
      realtimeSubscribe: listener => {
        let stopped = false, ws, timer, attempt = 0, lost = false;
        const tell = r => { try { listener(r); } catch { /* listener errors never stop the socket */ } };
        const down = () => { if (!lost) { lost = true; tell('connection-lost'); } };
        const later = ms => { if (!stopped) timer = setTimeout(connect, ms); };
        const backoff = () => { down(); const base = Math.min(300000, 5000 * 2 ** Math.min(attempt++, 6)); later(base / 2 + Math.random() * base / 2); };
        const connect = async () => {
          if (stopped || status !== 'restored') return;
          let r;
          try { r = await send({ type: 'ticket' }); } catch { r = { unavailable: true }; }
          if (stopped) return;
          if (r.signedOut) { status = 'idle'; down(); return; }
          if (!r.ticket) return backoff();
          let w;
          try { w = new WebSocket(r.url, ['otpanda.v1', r.ticket]); } catch { return backoff(); }
          ws = w;
          w.onopen = () => { attempt = 0; lost = false; tell('connection-restored'); tell('connect'); };
          w.onmessage = e => { if (e.data === '{"v":1,"t":"changed"}') tell('changed'); else w.close(4002); };
          w.onerror = () => {};
          w.onclose = async e => {
            if (ws === w) ws = undefined;
            if (stopped) return;
            down();
            if (e.code === 4401 || e.code === 4408) {
              try { const m = await send({ type: 'maintain', force: true }); if (m && m.signedOut === true) { status = 'idle'; return; } } catch { /* unavailable */ }
              if (e.code === 4408) return later(1000 + Math.random() * 1000);
            }
            backoff();
          };
        };
        connect();
        return () => { stopped = true; clearTimeout(timer); const w = ws; ws = undefined; if (w) { w.onclose = null; try { w.close(); } catch { /* already closed */ } } };
      },
      onProfileRevoked: () => {},
      profileRevoked: () => false,
      profileRead: () => '',
      profileWrite: () => {},
      profileClear: () => {},
      view: () => 0,
      setView: () => {},
      email: () => '',
      pendingLabel: () => '',
      assignmentState: () => 'unsupported',
      assignmentDismiss: () => {},
      googleLinkResult: () => '',
      firstPasskeyAvailable: () => false,
      extensionPopup: () => true,
      extensionIntent: () => '',
      extensionCancel: () => {},
      extensionConnect: async () => 'expired',
      connectGoogle: async () => 'unavailable',
      ...Object.fromEntries(['assignmentPrepare', 'assignmentConfirm', 'assignmentReconcile', 'entryEdit', 'entryDomains', 'addTotp', 'totpCode', 'connectGmail', 'disconnectGmail', 'gmailSourceStatus', 'signupEmail', 'firstPasskey', 'addPasskey', 'googleContinue', 'googleStart', 'protectionContinue', 'security'].map(n => [n, async () => { throw Error('unsupported'); }])),
    }),
  });
})();
