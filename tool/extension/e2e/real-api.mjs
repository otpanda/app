// Real API source (OTPANDA_API_SRC checkout) behind the e2e stand-in's web side. Extension routes and the three
// extension reads are the REAL handlers over real SQLite semantics (the API's own test D1 shim), not a D1 runtime.
// The web sign-in itself (passkey/Google) is not exercised: a real web session is minted through the API's own
// passkey signup fixture and handed out by the stand-in's /auth/exchange.
import path from 'node:path';
import { pathToFileURL } from 'node:url';
export async function realApi(src, { redirects, extensionOrigin }) {
  const imp = f => import(pathToFileURL(path.join(src, f)).href);
  const [{ database }, { AccountIdentityService }, { PasskeySignupService }, { DeviceSessionService }, { CodeCipher }, { SourceEntryStore }, ea, nat, ext, rd, ed, { authenticator }] = await Promise.all([
    'test/sqlite-helper.js', 'src/account-identity.js', 'src/passkey-signup.js', 'src/device-sessions.js', 'src/code-cipher.js', 'src/source-entries.js', 'src/entry-access.js', 'src/native-sessions.js', 'src/extension-http.js', 'src/device-read-http.js', 'src/entry-domains-http.js', 'test/passkey-fixture.js',
  ].map(imp));
  const clock = () => Date.now(), NOW = Date.now(), db = database();
  const identity = new AccountIdentityService(db, { clock }), signup = new PasskeySignupService(db, { clock });
  const e = await identity.issueEmailChallenge({ purpose: 'signup-email', email: 'e2e@example.test' });
  const c = await signup.begin({ email: 'e2e@example.test', emailToken: e.token, binding: 'b' }), a = authenticator();
  const account = await signup.finish({ token: c.token, binding: 'b', response: a.registration({ expected: c.options.challenge }) });
  const sessions = new DeviceSessionService(db, { clock }), web = await sessions.issue({ proof: { ...account, purpose: 'authenticate', verifiedAt: NOW }, clientKind: 'web' });
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const cipher = new CodeCipher({ keys: new Map([['k', key]]), activeKeyId: 'k' }), sources = new SourceEntryStore(db, cipher), access = new ea.EntryAccess(db, sources);
  const profile = nat.extensionProfile(Object.values(redirects));
  const extension = new nat.NativeSessionService(db, { clock, profile });
  const extHttp = ext.createExtensionHttp({ sessions, extension, db, redirects, extensionOrigins: [extensionOrigin], clock });
  const reads = rd.createDeviceReadHttp({ db, sessions, sources, access, clock, extensionOrigins: [extensionOrigin] });
  const domains = ed.createEntryDomainsHttp({ db, sessions, clock, extensionOrigins: [extensionOrigin] });
  const source = await sources.createSource(account.ownerId, 'sms', 'Private phone', NOW), entry = await sources.createEntry(account.ownerId, 'test', 'Test', NOW);
  await sources.receive(account.ownerId, { sourceId: source, eventId: 'one', code: '123456', receivedAt: NOW, expiresAt: NOW + 3600000 }); await sources.confirm(account.ownerId, source, 'one', entry, NOW);
  return {
    webAccess: web.access,
    fetch: (request, meta) => { const p = new URL(request.url).pathname; return p.startsWith('/auth/extension/') ? extHttp.fetch(request, meta) : p === '/v1/manage/entry/domains' ? domains.fetch(request, meta) : reads.fetch(request, meta); },
    revokeAll: () => db.sqlite.prepare("UPDATE device_sessions SET revoked_at=? WHERE client_kind='extension' AND revoked_at IS NULL").run(Date.now()),
    revoked: () => db.sqlite.prepare("SELECT device_id, revoked_at FROM device_sessions WHERE client_kind='extension' ORDER BY created_at").all(),
    close: () => db.sqlite.close(),
  };
}
