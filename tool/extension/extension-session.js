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
  let status = 'idle';
  const map = s => (s === 'signed-in' ? 'restored' : s === 'signing-in' ? 'restoring' : 'idle');
  const ready = (async () => { try { status = map(await send({ type: 'status' })); } catch { status = 'idle'; } })();
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
    }),
  });
})();
