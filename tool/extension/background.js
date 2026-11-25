// Extension background worker. The only place the sign-in record, key, PKCE verifier and bearer exist.
// Trusted extension contexts only: chrome.storage.session keeps its default access level, there is no
// content script, no externally_connectable and no onMessageExternal, and messages are accepted only from
// this extension's own popup page.
import { createExtensionAuth, idbRecords } from './extension-auth.mjs';
import config from './extension-config.mjs';

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
const handlers = {
  status: () => auth.status(),
  signIn: () => auth.signIn(),
  logout: async () => { await auth.logout(); return {}; },
  read: m => auth.read(m.path),
};
chrome.runtime.onMessage.addListener((m, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.url !== POPUP || !m || typeof m.type !== 'string' || !Object.hasOwn(handlers, m.type)) return false;
  ready.then(() => handlers[m.type](m)).then(v => respond({ ok: true, value: v }), () => respond({ ok: false }));
  return true;
});
