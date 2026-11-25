/* Loaded BEFORE session-bootstrap.js. Defines a factory only; the bootstrap
 * hands it narrow capabilities and keeps the access token in its own closure.
 * Nothing here is persisted except a short-lived random mailbox binding in
 * sessionStorage (per email and phase). Codes, grants, ceremony tokens and the
 * access token are never stored or passed to Flutter. */
(() => {
  'use strict';
  const TOKEN = /^otpda_[A-Za-z0-9_-]{55}$/, CHALLENGE = /^[A-Za-z0-9_-]{43}$/;
  const BINDING_KEY = 'otpanda.recovery.binding.v1.', BINDING_TTL = 30 * 60 * 1000; // matches the server's mailbox code lifetime (30 min);
  const KINDS = ['email-escape-on', 'email-escape-off', 'passkey-revoke', 'session-revoke', 'google-unlink'];
  // Low-entropy browser and OS family for the device list. Closed enums, never
  // a version, model or identifier. Client Hints brands/platform first, then
  // the UA string. Unknown is 'other'.
  const BROWSERS = ['chrome', 'edge', 'firefox', 'safari', 'opera', 'samsung', 'other'];
  const SYSTEMS = ['android', 'windows', 'mac', 'ios', 'linux', 'chromeos', 'other'];
  const detectDevice = nav => {
    const ua = String(nav?.userAgent ?? ''), hints = nav?.userAgentData;
    const brands = Array.isArray(hints?.brands) ? hints.brands.map(b => String(b?.brand ?? '')) : [];
    let browser = 'other';
    if (brands.includes('Microsoft Edge') || /\b(Edg|EdgA|EdgiOS)\//.test(ua)) browser = 'edge';
    else if (brands.includes('Opera') || /\b(OPR|OPT)\/|Opera/.test(ua)) browser = 'opera';
    else if (/SamsungBrowser\//.test(ua) || brands.includes('Samsung Internet')) browser = 'samsung';
    else if (/Firefox\/|FxiOS\//.test(ua)) browser = 'firefox';
    else if (brands.includes('Google Chrome') || /Chrome\/|CriOS\//.test(ua)) browser = 'chrome';
    else if (/Safari\//.test(ua)) browser = 'safari';
    const plat = String(hints?.platform ?? '');
    let os = 'other';
    if (plat === 'Android' || /Android/.test(ua)) os = 'android';
    else if (plat === 'Windows' || /Windows/.test(ua)) os = 'windows';
    else if (plat === 'Chrome OS' || /CrOS/.test(ua)) os = 'chromeos';
    else if (/iPhone|iPad|iPod/.test(ua) || plat === 'iOS') os = 'ios';
    else if (plat === 'macOS' || /Mac OS X|Macintosh/.test(ua)) os = 'mac';
    else if (plat === 'Linux' || /Linux|X11/.test(ua)) os = 'linux';
    return { browser, os };
  };
  globalThis.OTPandaDetectDevice = detectDevice;
  globalThis.OTPandaRecoveryFactory = caps => {
    const { api, access, generation, readBounded, encode, decode, random, fetchImpl, credentials, storage } = caps;
    const canonical = email => {
      if (typeof email !== 'string') throw Error('Email required');
      const e = email.trim().toLowerCase();
      if (e.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) throw Error('Email required');
      return e;
    };
    const bind = (phase, email) => {
      const binding = random() + random().slice(0, 11); // 43 + 11 chars, >= 32
      try { storage.setItem(BINDING_KEY + phase, JSON.stringify({ email, binding, at: Date.now() })); } catch { throw Error('Storage unavailable'); }
      return binding;
    };
    const binding = (phase, email) => {
      let v;
      try { v = JSON.parse(storage.getItem(BINDING_KEY + phase)); } catch { v = undefined; }
      if (!v || v.email !== email || typeof v.binding !== 'string' || !Number.isSafeInteger(v.at) || Date.now() - v.at > BINDING_TTL || v.at > Date.now()) throw Error('Request a new code');
      return v.binding;
    };
    const drop = phase => { try { storage.removeItem(BINDING_KEY + phase); } catch {} };
    // `final` marks the one request per operation that may commit a change. If its
    // outcome cannot be read (network loss, timeout, 5xx, unreadable body) the
    // change may or may not have happened: that is `unknown`, never `refused`.
    const unknown = () => Object.assign(Error('Outcome unknown'), { unknown: true });
    const call = async (path, { method = 'POST', body, bearer, final = false, signal } = {}) => {
      const headers = {};
      if (bearer) headers.Authorization = 'Bearer ' + bearer;
      if (method === 'POST') headers['Content-Type'] = 'application/json';
      let r;
      try { r = await fetchImpl(api + path, { method, credentials: 'omit', cache: 'no-store', redirect: 'error', headers, ...(signal ? { signal } : {}), ...(method === 'POST' ? { body: JSON.stringify(body) } : {}) }); }
      catch { throw final ? unknown() : Error('Network error'); }
      if (!r.ok) {
        // 408 and 5xx are unknown. Any other 4xx means this request was not accepted; after an earlier unknown, a 403/409 replay may reflect the earlier request, so callers must not read it as history.
        if (final && (r.status >= 500 || r.status === 408 || !Number.isInteger(r.status))) throw unknown();
        throw Error('Request failed');
      }
      let value;
      try { const text = await readBounded(r, 24576); value = text ? JSON.parse(text) : undefined; } catch { value = undefined; }
      if (!value || typeof value !== 'object') throw final ? unknown() : Error('Unexpected response');
      return value;
    };
    const signed = () => { const token = access(); if (!token) throw Error('Sign in again'); return token; };
    const assertion = async c => {
      const o = c?.options;
      if (!TOKEN.test(c?.token) || o?.rpId !== 'otpanda.github.io' || o.userVerification !== 'required' || !CHALLENGE.test(o.challenge) || !Array.isArray(o.allowCredentials) || o.allowCredentials.length > 50 || !Number.isSafeInteger(c.expiresAt) || c.expiresAt <= Date.now() || c.expiresAt > Date.now() + 120000) throw Error('Invalid passkey verification');
      const cred = await credentials.get({ publicKey: { rpId: 'otpanda.github.io', challenge: decode(o.challenge), userVerification: 'required', timeout: Math.min(120000, c.expiresAt - Date.now()), allowCredentials: o.allowCredentials.map(v => ({ type: 'public-key', id: decode(v.id) })) } });
      if (!cred) throw Error('Passkey verification cancelled');
      return { id: cred.id, rawId: encode(new Uint8Array(cred.rawId)), type: cred.type, clientExtensionResults: cred.getClientExtensionResults(), response: { clientDataJSON: encode(new Uint8Array(cred.response.clientDataJSON)), authenticatorData: encode(new Uint8Array(cred.response.authenticatorData)), signature: encode(new Uint8Array(cred.response.signature)), userHandle: cred.response.userHandle ? encode(new Uint8Array(cred.response.userHandle)) : null } };
    };
    // Registers a NEW passkey for the ceremony returned by complete-begin.
    const registration = async c => {
      const o = c?.options;
      if (!TOKEN.test(c?.token) || o?.rp?.id !== 'otpanda.github.io' || o.rp.name !== 'OTPanda' || !CHALLENGE.test(o.challenge) || !Number.isSafeInteger(c.expiresAt) || c.expiresAt <= Date.now() || c.expiresAt > Date.now() + 120000 || o.authenticatorSelection?.userVerification !== 'required' || !Array.isArray(o.excludeCredentials) || o.excludeCredentials.length > 10 || o.excludeCredentials.some(v => v.type !== 'public-key' || typeof v.id !== 'string' || !/^[A-Za-z0-9_-]{1,1400}$/.test(v.id))) throw Error('Invalid passkey setup');
      const cred = await credentials.create({ publicKey: { rp: o.rp, user: { ...o.user, id: decode(o.user.id) }, challenge: decode(o.challenge), pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }], timeout: Math.min(120000, c.expiresAt - Date.now()), attestation: 'none', authenticatorSelection: { residentKey: 'required', userVerification: 'required' }, excludeCredentials: o.excludeCredentials.map(v => ({ type: 'public-key', id: decode(v.id) })) } });
      if (!cred || cred.type !== 'public-key') throw Error('Passkey setup cancelled');
      return { id: cred.id, rawId: encode(new Uint8Array(cred.rawId)), type: cred.type, clientExtensionResults: cred.getClientExtensionResults(), response: { clientDataJSON: encode(new Uint8Array(cred.response.clientDataJSON)), attestationObject: encode(new Uint8Array(cred.response.attestationObject)), transports: cred.response.getTransports?.() ?? [] } };
    };
    const humanCode = code => {
      const c = String(code).replaceAll(' ', '').replaceAll('-', '').trim().toUpperCase();
      if (!/^[A-HJ-NP-Z2-9]{8}$/.test(c)) throw Error('Code required');
      return c;
    };
    // Mutating operations resolve to 'ok' | 'refused' | 'unknown' instead of
    // throwing, so the UI can tell "nothing changed" from "may have changed".
    const outcome = fn => async (...args) => {
      try { await fn(...args); return 'ok'; } catch (e) { return e?.unknown ? 'unknown' : 'refused'; }
    };
    // Tells the server which browser and OS this session runs on, so the
    // device list can name it. Label only: nothing here is an identity. Once
    // per session generation and value; any failure is ignored.
    let described = '', inflight = null, inflightKey = '';
    const DESCRIBE_WAIT_MS = 2000, DESCRIBE_DEADLINE_MS = 15000;
    const describeSelf = async () => {
      try {
        const nav = caps.navigator ?? globalThis.navigator;
        const { browser, os } = detectDevice(nav);
        if (!BROWSERS.includes(browser) || !SYSTEMS.includes(os)) return;
        const gen = generation(), key = gen + ':' + browser + ':' + os;
        if (key === described) return;
        // One request per generation and value, even if status runs again
        // while it is still pending. It may hang: nothing waits on it beyond
        // the short deadline below, and a late answer for an older session
        // marks nothing.
        if (!inflight || inflightKey !== key) {
          const ctl = typeof AbortController === 'function' ? new AbortController() : undefined;
          const bearer = signed();
          inflightKey = key;
          // The 15 s deadline settles this promise itself, so a fetch or body
          // read that ignores the abort cannot hold it open: inflight clears
          // and a later status may describe again.
          let timer;
          const deadline = new Promise(r => { timer = setTimeout(() => { try { ctl?.abort(); } catch {} r(); }, DESCRIBE_DEADLINE_MS); });
          const work = (async () => {
            try {
              const done = await call('/v1/manage/session/describe', { body: { browser, os, name: null }, bearer, signal: ctl?.signal });
              if (done.ok === true && generation() === gen) described = key;
            } catch {}
          })();
          const mine = inflight = Promise.race([work, deadline]).finally(() => { clearTimeout(timer); if (inflight === mine) inflight = null; });
        }
        let wait;
        await Promise.race([inflight, new Promise(r => { wait = setTimeout(r, DESCRIBE_WAIT_MS); })]);
        clearTimeout(wait);
      } catch {}
    };
    const ops = {
      status: async () => {
        await describeSelf();
        return JSON.stringify(await call('/v1/manage/recovery/status', { method: 'GET', bearer: signed() }));
      },
      change: async (kind, target = '', warningAccepted = false) => {
        if (!KINDS.includes(kind)) throw Error('Known change required');
        const bearer = signed(), attempt = generation();
        const needsTarget = kind === 'passkey-revoke' || kind === 'session-revoke', on = kind === 'email-escape-on';
        if (needsTarget && (typeof target !== 'string' || !target || target.length > 512)) throw Error('Target required');
        if (on && warningAccepted !== true) throw Error('Warning must be accepted');
        const base = { kind, ...(needsTarget ? { target } : {}), ...(on ? { warningAccepted: true } : {}) };
        const c = await call('/v1/manage/recovery/begin', { body: base, bearer });
        const response = await assertion(c);
        if (attempt !== generation()) throw Error('Cancelled');
        // Success may legitimately end this very session (self sign-out): no
        // authenticated follow-up is required or attempted here.
        await call('/v1/manage/recovery/finish', { body: { ...base, response, token: c.token }, bearer, final: true });
      },
      // Display name only: no passkey check. Null removes the name.
      renamePasskey: async (credentialId, label) => {
        if (typeof credentialId !== 'string' || !credentialId || credentialId.length > 512) throw Error('Passkey required');
        let name = null;
        if (label !== null && label !== undefined && label !== '') {
          if (typeof label !== 'string') throw Error('Name required');
          name = label.normalize('NFC').trim();
          if (name.length < 1 || name.length > 40 || /[\u0000-\u001f\u007f-\u009f]/.test(name)) throw Error('Name required');
        }
        const done = await call('/v1/manage/passkey/rename', { body: { credentialId, label: name }, bearer: signed(), final: true });
        if (done.ok !== true) throw unknown();
      },
      cancelRequest: async requestId => {
        if (typeof requestId !== 'string' || !requestId || requestId.length > 128) throw Error('Request required');
        await call('/v1/manage/recovery/cancel-request', { body: { requestId }, bearer: signed(), final: true });
      },
      start: async email => {
        const e = canonical(email);
        await call('/auth/recovery/email/request', { body: { binding: bind('request', e), email: e } });
      },
      verify: async (email, code) => {
        const e = canonical(email), b = binding('request', e);
        const v = await call('/auth/recovery/email/verify', { body: { binding: b, code: humanCode(code), email: e } });
        if (v.status !== 'waiting' || !Number.isSafeInteger(v.availableAt)) throw Error('Unexpected response');
        drop('request');
        return v.availableAt;
      },
      sendCompletionCode: async email => {
        const e = canonical(email);
        await call('/auth/recovery/email/complete-code', { body: { binding: bind('complete', e), email: e } });
      },
      complete: async (email, code) => {
        const e = canonical(email), b = binding('complete', e);
        const begun = await call('/auth/recovery/email/complete-begin', { body: { binding: b, code: humanCode(code), email: e } });
        drop('complete'); // the code is consumed; a retry needs a fresh one
        if (!TOKEN.test(begun.grant) || !begun.ceremony) throw Error('Unexpected response');
        const response = await registration(begun.ceremony);
        const done = await call('/auth/recovery/email/complete-finish', { body: { grant: begun.grant, response, token: begun.ceremony.token }, final: true });
        if (done.status !== 'completed') throw unknown();
      },
    };
    return {
      ...ops,
      change: outcome(ops.change),
      cancelRequest: outcome(ops.cancelRequest),
      renamePasskey: outcome(ops.renamePasskey),
      complete: outcome(ops.complete),
    };
  };
})();
