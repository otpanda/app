const test = require('node:test'), assert = require('node:assert');
const { parseNativeIntent, nativeApproveUrl } = require('../tool/native-launch-intent.js');
const C = 'A'.repeat(43), S = 'b-_'.padEnd(43, 'c');
test('accepts exactly native, challenge and state', () => {
  const i = parseNativeIntent(`#native=1&challenge=${C}&state=${S}`);
  assert.deepStrictEqual(i, { challenge: C, state: S });
  const u = new URL(nativeApproveUrl(i));
  assert.equal(u.origin, 'https://otpanda-api.abrahammurciano.workers.dev');
  assert.equal(u.pathname, '/auth/native/approve');
  assert.equal(u.searchParams.get('redirect_uri'), 'https://otpanda-api.abrahammurciano.workers.dev/app-return');
  assert.equal([...u.searchParams.keys()].sort().join(), 'challenge,redirect_uri,state');
  assert.equal(u.hash, '');
});
test('refuses extras, duplicates, bad lengths and wrong flag', () => {
  for (const h of [
    '', `native=1&challenge=${C}&state=${S}`, `#native=1&challenge=${C}`,
    `#native=1&challenge=${C}&state=${S}&redirect_uri=https://evil.example/`,
    `#native=1&challenge=${C}&challenge=${C}&state=${S}`,
    `#native=2&challenge=${C}&state=${S}`, `#native=1&challenge=${C}x&state=${S}`,
    `#native=1&challenge=${C}&state=${S.slice(1)}`, `#native=1&challenge=${C}&state=${'+'.repeat(43)}`,
    `#native=1&challenge&state=${S}`,
  ]) assert.equal(parseNativeIntent(h), null, h);
});
test('provider=google and remember are optional, strict and never reach the approve URL', () => {
  assert.deepStrictEqual(parseNativeIntent(`#native=1&challenge=${C}&state=${S}&provider=google`), { challenge: C, state: S, provider: 'google' });
  assert.deepStrictEqual(parseNativeIntent(`#native=1&challenge=${C}&state=${S}&provider=google&remember=0`), { challenge: C, state: S, provider: 'google', remember: false });
  assert.deepStrictEqual(parseNativeIntent(`#native=1&challenge=${C}&state=${S}&provider=google&remember=1`), { challenge: C, state: S, provider: 'google', remember: true });
  for (const h of [`#native=1&challenge=${C}&state=${S}&provider=apple`, `#native=1&challenge=${C}&state=${S}&remember=1`, `#native=1&challenge=${C}&state=${S}&provider=google&remember=yes`, `#native=1&challenge=${C}&state=${S}&provider=Google`, `#native=1&challenge=${C}&state=${S}&provider=google&x=1`]) assert.equal(parseNativeIntent(h), null, h);
  const u = new URL(nativeApproveUrl(parseNativeIntent(`#native=1&challenge=${C}&state=${S}&provider=google&remember=0`)));
  assert.equal([...u.searchParams.keys()].sort().join(), 'challenge,redirect_uri,state');
});
