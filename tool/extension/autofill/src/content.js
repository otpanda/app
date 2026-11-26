// Content script glue (registered only for exact-host patterns, built into a classic script by build-content.mjs). All decisions live in
// content-core.js. It asks with an argument-free message, never reads the page URL, never stores a code.
import { createContentController } from './content-core.js';
export { MIN_GAP_MS } from './content-core.js';
const c = createContentController({ doc: document, win: globalThis, send: () => chrome.runtime.sendMessage({ type: 'otpanda-fill-request' }) });
new MutationObserver(() => c.attempt()).observe(document, { childList: true, subtree: true });
document.addEventListener('visibilitychange', () => c.attempt());
globalThis.addEventListener('focus', () => c.attempt());
globalThis.addEventListener('pagehide', () => c.pagehide());
globalThis.addEventListener('pageshow', () => c.pageshow());
c.attempt();
