// Service-worker decision for a fill request. The page host comes ONLY from browser-provided sender data (sender.url of the requesting frame),
// never from a claim in the message. The code goes back only to the requesting frame, only when exactly one eligible entry has a fresh,
// unexpired code. Several eligible entries with fresh codes, or none, release nothing (the popup lists candidates instead).
import { eligibleEntries } from './match.js';
export const FRESH_MS = 5 * 60_000;
export async function handleFillRequest({ message, sender, entries, codes, clock = Date.now, extensionId }) {
 const none = Object.freeze({ status: 'none' });
 if (!message || message.type !== 'otpanda-fill-request' || Object.keys(message).length !== 1) return none;
 if (!sender || sender.id !== extensionId || !sender.tab || typeof sender.url !== 'string' || !Number.isSafeInteger(sender.frameId)) return none;
 const eligible = eligibleEntries(sender.url, await entries());
 if (!eligible.length) return none;
 const now = clock(), fresh = [];
 for (const entryId of eligible) {
  let c; try { c = await codes(entryId); } catch { continue; }
  if (c && c.entryId === entryId && typeof c.code === 'string' && /^[0-9A-Za-z]{4,10}$/.test(c.code) && Number.isSafeInteger(c.receivedAt) && Number.isSafeInteger(c.expiresAt) && c.expiresAt > now && c.receivedAt <= now && now - c.receivedAt <= FRESH_MS) fresh.push(c);
 }
 if (fresh.length === 0) return none;
 if (fresh.length > 1) return Object.freeze({ status: 'ambiguous', count: fresh.length });
 return Object.freeze({ status: 'ok', code: fresh[0].code, expiresAt: fresh[0].expiresAt });
}
