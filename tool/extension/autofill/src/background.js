// Service worker glue. Inert until a CodeSource (authenticated entries, domains and codes) is supplied by the login work: with no source it
// registers nothing and answers every fill request with {status:'none'}.
import { handleFillRequest } from './fill-request.js';
import { matchPatterns } from './match.js';
export const SCRIPT_ID = 'otpanda-autofill';
export const CONTENT_PATH = 'autofill/content.js'; // where package.mjs places the classic bundle
// source: { entries(): Promise<[{entryId,domains}]>, code(entryId): Promise<{entryId,code,receivedAt,expiresAt}> } or undefined.
export function createBackground({ chromeApi, source, clock = Date.now }) {
 const extensionId = chromeApi.runtime.id;
 chromeApi.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // Only fill requests are ours: popup messages (other listener) must not be answered here.
  if (!message || message.type !== 'otpanda-fill-request') return false;
  if (!source) { sendResponse({ status: 'none' }); return false; }
  handleFillRequest({ message, sender, entries: () => source.entries(), codes: id => source.code(id), clock, extensionId })
   .then(sendResponse, () => sendResponse({ status: 'none' }));
  return true; // async response
 });
 // Registers the content script ONLY for exact-host patterns that are BOTH current candidates and already granted by the user (partial grants
 // work: a new association is simply not injected until the user grants it). Granted https origins that are no longer candidates (an association
 // removed, an entry deleted, or revokeAll on sign-out) are removed, never the manifest's required host permissions. A failed candidate read
 // (offline, signed out) unregisters and revokes nothing: fail closed on injection, no grant change on a transient error.
 // Returns {registered, patterns (the candidates), revoked}.
 async function doSync({ revokeAll = false } = {}) {
  if (!source) return { registered: 0, patterns: [], revoked: 0 };
  const unreg = async () => { try { await chromeApi.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }); } catch { /* not registered yet */ } };
  let patterns;
  try { patterns = revokeAll ? [] : matchPatterns(await source.entries()); } catch { await unreg(); return { registered: 0, patterns: [], revoked: 0, failed: true }; }
  const granted = (await chromeApi.permissions.getAll().catch(() => ({ origins: [] }))).origins ?? [];
  const required = chromeApi.runtime.getManifest?.().host_permissions ?? [];
  const stale = granted.filter(o => typeof o === 'string' && o.startsWith('https://') && !required.includes(o) && !patterns.includes(o));
  let revoked = 0;
  if (stale.length) { try { if (await chromeApi.permissions.remove({ origins: stale })) revoked = stale.length; } catch { /* keep going */ } }
  const active = patterns.filter(o => granted.includes(o));
  await unreg();
  if (!active.length) return { registered: 0, patterns, revoked };
  await chromeApi.scripting.registerContentScripts([{ id: SCRIPT_ID, matches: active, js: [CONTENT_PATH], allFrames: true, matchOriginAsFallback: false, runAt: 'document_idle', persistAcrossSessions: true }]);
  return { registered: active.length, patterns, revoked };
 }
 // Serialized + coalesced: one sync runs at a time, and every step (candidate read, getAll, remove, unregister, register) happens inside that one
 // critical section, so overlapping triggers (grant event, sign-in, logout) cannot interleave. Calls arriving while one runs share ONE queued follow-up
 // run whose options are the LATEST caller's (logout after sign-in wins), so the final registration reflects the last request.
 let running, queued;
 function syncContentScripts(opts = {}) {
  if (queued) { queued.opts = opts; return queued.promise; }
  const job = { opts };
  job.promise = (running ?? Promise.resolve()).catch(() => {}).then(() => { queued = undefined; const r = doSync(job.opts); running = r; return r; });
  queued = job;
  return job.promise;
 }
 // Grant/revoke signals: the user granting or removing the optional origins re-syncs the registration (revoked => unregistered, none => nothing).
 const resync = () => { syncContentScripts().catch(() => {}); };
 chromeApi.permissions?.onAdded?.addListener?.(resync);
 chromeApi.permissions?.onRemoved?.addListener?.(resync);
 chromeApi.runtime.onStartup?.addListener?.(resync);
 chromeApi.runtime.onInstalled?.addListener?.(resync);
 return Object.freeze({ syncContentScripts });
}
