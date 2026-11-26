// Worker-side composition for the autofill CodeSource. Imported only by the opt-in sign-in worker. It receives the auth object's
// worker-only readInternal and nothing else: no `read`, no popup path, and it registers no message listener. The catalogue is fetched with no
// credentials and stored in chrome.storage.local (rows only, <=2 MiB parsed upstream; not a secret).
import { createCatalogueCache, createCodeSource } from './code-source.js';
export const CATALOGUE_STORE_KEY = 'otpanda-2fad-catalogue-v1';
export function createAutofillSource({ readInternal, storageLocal, fetchImpl, clock = Date.now, mono = () => performance.now() }) {
 if (typeof readInternal !== 'function' || !storageLocal || typeof fetchImpl !== 'function') throw new Error('wiring');
 const store = {
  get: async () => (await storageLocal.get(CATALOGUE_STORE_KEY))[CATALOGUE_STORE_KEY],
  set: v => storageLocal.set({ [CATALOGUE_STORE_KEY]: v }),
 };
 const catalogue = createCatalogueCache({ fetchText: url => fetchImpl(url, { credentials: 'omit', redirect: 'error', cache: 'no-store' }), store, clock });
 return createCodeSource({ read: p => readInternal(p), catalogue, clock, mono });
}
