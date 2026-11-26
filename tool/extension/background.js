// Extension background worker. The only place the sign-in record, key, PKCE verifier and bearer exist.
// Trusted extension contexts only: chrome.storage.session keeps its default access level, there is no
// content script, no externally_connectable and no onMessageExternal, and messages are accepted only from
// this extension's own popup page.
import { createExtensionAuth, idbRecords } from './extension-auth.mjs';
import config from './extension-config.mjs';
import { createBackground as createAutofill } from './autofill/src/background.js';
import { createAutofillSource } from './autofill/src/wiring.js';

const area = chrome.storage.session;
const auth = createExtensionAuth({
  ...config,
  identity: chrome.identity,
  fetch: (...a) => fetch(...a),
  records: idbRecords(indexedDB),
  session: {
    get: async k => (await area.get(k))[k],
    set: (k, v) => area.set({ [k]: v }),
    remove: k => area.remove(k),
  },
});
const POPUP = chrome.runtime.getURL('index.html');
const ready = auth.recover();
// Autofill: its source gets the worker-only generated-code read and nothing else. Inert until the user grants the optional origins.
const autofillSource = createAutofillSource({ readInternal: p => ready.then(() => auth.readInternal(p)), storageLocal: chrome.storage.local, fetchImpl: (...a) => fetch(...a) });
const autofill = createAutofill({ chromeApi: chrome, source: autofillSource });
const handlers = {
  status: () => auth.status(),
  signIn: async () => { const v = await auth.signIn(); autofill.syncContentScripts().catch(() => {}); return v; },
  logout: async () => { await auth.logout(); await autofill.syncContentScripts().catch(() => {}); return {}; },
  read: m => auth.read(m.path),
  maintain: m => auth.maintain(m.force === true),
  ticket: () => auth.ticket(),
  // Opening the settings row calls this: it re-syncs registration/grants against the CURRENT associations and returns the candidate origins.
  autofillOrigins: async () => { const r = await autofill.syncContentScripts(); if (r.failed) throw new Error('origins'); return { origins: r.patterns }; },
};
chrome.runtime.onMessage.addListener((m, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.url !== POPUP || !m || typeof m.type !== 'string' || !Object.hasOwn(handlers, m.type)) return false;
  ready.then(() => handlers[m.type](m)).then(v => respond({ ok: true, value: v }), () => respond({ ok: false }));
  return true;
});
