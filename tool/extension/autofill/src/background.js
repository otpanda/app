// Service worker glue. Inert until a CodeSource (authenticated entries, domains and codes) is supplied by the login work: with no source it
// registers nothing and answers every fill request with {status:'none'}.
import { handleFillRequest } from './fill-request.js';
import { matchPatterns } from './match.js';
export const SCRIPT_ID = 'otpanda-autofill';
// source: { entries(): Promise<[{entryId,domains}]>, code(entryId): Promise<{entryId,code,receivedAt,expiresAt}> } or undefined.
export function createBackground({ chromeApi, source, clock = Date.now }) {
 const extensionId = chromeApi.runtime.id;
 chromeApi.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!source) { sendResponse({ status: 'none' }); return false; }
  handleFillRequest({ message, sender, entries: () => source.entries(), codes: id => source.code(id), clock, extensionId })
   .then(sendResponse, () => sendResponse({ status: 'none' }));
  return true; // async response
 });
 // Registers the content script ONLY for exact-host patterns. Requires the optional host permission the user granted explicitly.
 async function syncContentScripts() {
  if (!source) return { registered: 0 };
  const patterns = matchPatterns(await source.entries());
  const granted = await chromeApi.permissions.contains({ origins: patterns.length ? patterns : ['https://invalid.invalid/*'] }).catch(() => false);
  try { await chromeApi.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }); } catch { /* not registered yet */ }
  if (!patterns.length || !granted) return { registered: 0 };
  await chromeApi.scripting.registerContentScripts([{ id: SCRIPT_ID, matches: patterns, js: ['src/content.js'], allFrames: true, matchOriginAsFallback: false, runAt: 'document_idle', persistAcrossSessions: true }]);
  return { registered: patterns.length };
 }
 return Object.freeze({ syncContentScripts });
}
