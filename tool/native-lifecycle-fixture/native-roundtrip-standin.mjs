// STAND-IN for the Android device, to prove the harness itself. It uses
// WebCrypto keys, NOT the Android Keystore, so it is not Keystore proof. The
// emulator test (integration_test/native_roundtrip_test.dart in the app repo)
// does the same steps with the real Keystore.
import assert from 'node:assert/strict';
import {createHash, webcrypto, createPublicKey} from 'node:crypto';
const B = process.argv[2] ?? 'http://127.0.0.1:8787';
const b64u = b => Buffer.from(b).toString('base64url');
const post = async (p, body, token) => { const r = await fetch(B + p, {method: 'POST', headers: {'content-type': 'application/json', ...(token ? {authorization: 'Bearer ' + token} : {})}, body: JSON.stringify(body)}); return {status: r.status, body: await r.json().catch(() => null)}; };
const get = async (p, token) => { const r = await fetch(B + p, {headers: {authorization: 'Bearer ' + token}}); return {status: r.status, body: await r.json().catch(() => null)}; };
const seed = await (await fetch(B + '/__harness/seed', {method: 'POST'})).json();
const key = await webcrypto.subtle.generateKey({name: 'ECDSA', namedCurve: 'P-256'}, false, ['sign']);
const pub = b64u(new Uint8Array(await webcrypto.subtle.exportKey('raw', key.publicKey)));
const verifier = b64u(webcrypto.getRandomValues(new Uint8Array(32)));
const challenge = createHash('sha256').update(verifier).digest('base64url');
const {code} = await (await fetch(B + '/__harness/mint', {method: 'POST', body: JSON.stringify({challenge})})).json();
const ex = await post('/auth/native/exchange', {code, verifier, redirect_uri: 'https://otpanda-api.abrahammurciano.workers.dev/app-return', renewal_key: pub});
assert.equal(ex.status, 200); const {access, device_id} = ex.body;
console.log('exchange 200, keys:', Object.keys(ex.body).sort().join(','));
const entries = await get('/v1/manage/entries', access); assert.equal(entries.status, 200);
console.log('entries:', JSON.stringify(entries.body).slice(0, 300));
const codes = await get('/v1/manage/active-codes', access); assert.equal(codes.status, 200);
console.log('active-codes:', JSON.stringify(codes.body).slice(0, 300));
const ren = await post('/v1/manage/entry/rename', {entryId: seed.entryId, label: 'Renamed by device'}, access); assert.equal(ren.status, 200);
assert.equal((await (await fetch(B + '/__harness/entry?id=' + seed.entryId)).json()).label, 'Renamed by device');
console.log('rename 200 and D1 label changed');
const ch = await post('/auth/native/challenge', {device_id, purpose: 'renew'}); assert.equal(ch.status, 200);
const msg = ['otpanda-native-v1', 'POST /auth/native/renew', device_id, ch.body.nonce, String(ch.body.expires_at)].join('\n');
const sig = b64u(new Uint8Array(await webcrypto.subtle.sign({name: 'ECDSA', hash: 'SHA-256'}, key.privateKey, new TextEncoder().encode(msg))));
const rb = {device_id, nonce: ch.body.nonce, expires_at: ch.body.expires_at, signature: sig};
assert.equal((await post('/auth/native/renew', rb)).status, 200); console.log('signed renewal 200');
assert.equal((await post('/auth/native/renew', rb)).status, 401); console.log('replay 401');
const bad = await post('/auth/native/challenge', {device_id, purpose: 'renew'});
const m2 = ['otpanda-native-v1', 'POST /auth/native/renew', device_id, bad.body.nonce, String(bad.body.expires_at + 1)].join('\n');
const s2 = b64u(new Uint8Array(await webcrypto.subtle.sign({name: 'ECDSA', hash: 'SHA-256'}, key.privateKey, new TextEncoder().encode(m2))));
assert.equal((await post('/auth/native/renew', {device_id, nonce: bad.body.nonce, expires_at: bad.body.expires_at, signature: s2})).status, 401); console.log('wrong-message signature 401');
assert.equal((await get('/v1/manage/session', 'x'.repeat(40))).status, 401); console.log('bad bearer 401');
console.log('STANDIN PASS');
