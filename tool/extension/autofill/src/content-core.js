// Content-script controller, DOM-agnostic and dependency-injected so it is tested without a browser. It decides WHEN to ask the service worker
// for a code; the worker still decides IF one is released (sender URL, exact host, one fresh entry). Rules, all checked again after the async
// answer arrives, so a page that changed or went to the background while we waited never receives the code:
//  - the document is visible AND focused (foreground tab in the focused window); never in a hidden, background or bfcached page
//  - top frame, or every ancestor origin equals this frame's own origin (Chrome ancestorOrigins). Unknown ancestry in a subframe fails closed.
//  - a detected, empty, rendered OTP field (not password, not disabled/readonly): never overwrites a value, and no request while one is filled
//  - requests are at least MIN_GAP_MS apart. Mutations during a request or a gap schedule ONE trailing attempt, never a storm.
//  - pagehide stops everything; pageshow (back/forward restore) re-evaluates. The page URL is never read.
import { findOtpTargets, fillTarget } from './fields.js';
export const MIN_GAP_MS = 10_000;
const MIN_SIZE = 8;
export function createContentController({ doc, win, send, now = Date.now, setTimer = (f, ms) => setTimeout(f, ms), clearTimer = id => clearTimeout(id), style = el => getComputedStyle(el) }) {
 let busy = false, again = false, lastCode = '', lastAt = -Infinity, timer, stopped = false;
 const foreground = () => doc.visibilityState === 'visible' && typeof doc.hasFocus === 'function' && doc.hasFocus() === true;
 const frameOk = () => {
  if (win.top === win) return true;
  const a = win.location?.ancestorOrigins;
  if (!a || typeof a.length !== 'number' || a.length === 0) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== win.location.origin) return false;
  return true;
 };
 const rendered = el => {
  const r = el.getBoundingClientRect();
  if (!(r.width >= MIN_SIZE && r.height >= MIN_SIZE)) return false;
  const s = style(el);
  return s.visibility !== 'hidden' && s.display !== 'none' && !(Number(s.opacity) === 0) && s.pointerEvents !== 'none';
 };
 const empty = g => g.every(el => el.value === '' || el.value === undefined);
 const targets = () => findOtpTargets(doc, { visible: rendered }).filter(empty);
 const eligible = () => !stopped && foreground() && frameOk();
 function schedule() {
  if (stopped || timer !== undefined) return;
  const wait = Math.max(0, lastAt + MIN_GAP_MS - now());
  timer = setTimer(() => { timer = undefined; attempt(); }, wait);
 }
 async function attempt() {
  if (!eligible()) return;
  if (busy) { again = true; return; }
  if (!targets().length) return;
  if (lastAt + MIN_GAP_MS - now() > 0) { schedule(); return; }
  lastAt = now(); busy = true;
  try {
   const r = await send();
   // Everything may have changed while the worker answered: recheck before any fill.
   if (r?.status === 'ok' && Number.isSafeInteger(r.expiresAt) && r.expiresAt > now() && r.code !== lastCode && eligible()) {
    for (const g of targets()) if (g.every(el => el.isConnected !== false) && fillTarget(g, r.code)) { lastCode = r.code; break; }
   }
  } catch { /* service worker asleep or extension reloaded: do nothing */ }
  finally { busy = false; if (again) { again = false; schedule(); } }
 }
 return Object.freeze({
  attempt,
  pagehide() { stopped = true; again = false; if (timer !== undefined) { clearTimer(timer); timer = undefined; } },
  pageshow() { stopped = false; attempt(); },
 });
}
