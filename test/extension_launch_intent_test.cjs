const test = require('node:test'), assert = require('node:assert');
const { parseExtensionIntent, validReturn } = require('../tool/extension-launch-intent.js');
const C = 'A'.repeat(43), S = 'b-_'.padEnd(43, 'c'), ID = 'a'.repeat(32);
test('accepts exactly extension, challenge, state and a known redirect key', () => {
  assert.deepStrictEqual(parseExtensionIntent(`#extension=1&challenge=${C}&redirect=chrome&state=${S}`), { challenge: C, state: S, redirect: 'chrome' });
  assert.deepStrictEqual(parseExtensionIntent(`#extension=1&challenge=${C}&redirect=firefox&state=${S}`), { challenge: C, state: S, redirect: 'firefox' });
});
test('refuses URLs, extras, duplicates, bad lengths and the native flag', () => {
  for (const h of ['', `extension=1&challenge=${C}&redirect=chrome&state=${S}`, `#extension=1&challenge=${C}&state=${S}`,
    `#extension=1&challenge=${C}&redirect=https://x.example/&state=${S}`, `#extension=1&challenge=${C}&redirect=chrome&state=${S}&native=1`,
    `#extension=1&challenge=${C}&challenge=${C}&redirect=chrome&state=${S}`, `#extension=0&challenge=${C}&redirect=chrome&state=${S}`,
    `#extension=1&challenge=${C}x&redirect=chrome&state=${S}`, `#native=1&challenge=${C}&state=${S}`, `#extension=1&challenge&redirect=chrome&state=${S}`, '#' + 'a'.repeat(600)]) assert.equal(parseExtensionIntent(h), null, h);
});
test('validReturn needs the chrome root, fragment code and exact state; firefox stays refused until its host is verified', () => {
  const ok = `https://${ID.replace(/a/g, 'b')}.chromiumapp.org/#code=${'c'.repeat(43)}&state=${S}`;
  assert.equal(validReturn(ok, S, 'chrome'), ok);
  assert.equal(validReturn(ok, S, 'firefox'), null);
  assert.equal(validReturn(ok.replace(S, 'z'.repeat(43)), S, 'chrome'), null);
  assert.equal(validReturn(ok.replace('/#', '/?a=1#'), S, 'chrome'), null);
  assert.equal(validReturn(ok.replace('b'.repeat(32), 'q'.repeat(32)), S, 'chrome'), null);
});
