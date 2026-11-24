const {test}=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');
const src=fs.readFileSync('tool/recovery-bridge.js','utf8');
const TOK='otpda_'+'a'.repeat(55),ACCESS='otpda_'+'b'.repeat(55),CH='A'.repeat(43);
const encode=b=>Buffer.from(b).toString('base64url'),decode=v=>new Uint8Array(Buffer.from(v,'base64url'));
function setup({signed=true,get,create,reply}={}){
  const calls=[],store=new Map();let n=0;
  const storage={getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>store.set(k,v),removeItem:k=>store.delete(k)};
  const ctx={};vm.createContext(ctx);vm.runInContext(src,ctx);
  const f=ctx.OTPandaRecoveryFactory;
  const resp=(status,obj)=>({ok:status<400,status,headers:{get:()=>null},body:{getReader(){let s=false;return{async read(){if(s)return{done:true};s=true;return{done:false,value:new TextEncoder().encode(JSON.stringify(obj))}},async cancel(){},releaseLock(){}}}}});
  const bridge=f({api:'https://api.test',access:()=>signed?ACCESS:undefined,generation:()=>1,
    readBounded:async r=>{const rd=r.body.getReader();const {value}=await rd.read();return value?new TextDecoder().decode(value):''},
    encode,decode,random:()=>encode(new Uint8Array(32).fill(++n)),
    fetchImpl:async(url,opts)=>{const path=url.replace('https://api.test','');calls.push({path,opts,body:opts.body?JSON.parse(opts.body):undefined});const r=reply?.(path,calls.at(-1));return r?resp(r.status??200,r.body):resp(200,{})},
    credentials:{get:get??(async()=>cred()),create:create??(async()=>reg())},storage});
  return{bridge,calls,store};
}
const buf=new Uint8Array([1,2,3]).buffer;
const cred=()=>({id:'AQID',rawId:buf,type:'public-key',getClientExtensionResults:()=>({}),response:{clientDataJSON:buf,authenticatorData:buf,signature:buf,userHandle:null}});
const reg=()=>({id:'AQID',rawId:buf,type:'public-key',getClientExtensionResults:()=>({}),response:{clientDataJSON:buf,attestationObject:buf,getTransports:()=>['internal']}});
const ceremony=()=>({token:TOK,expiresAt:Date.now()+100000,options:{rpId:'otpanda.github.io',challenge:CH,userVerification:'required',allowCredentials:[]}});
const regCeremony=()=>({token:TOK,expiresAt:Date.now()+100000,options:{rp:{id:'otpanda.github.io',name:'OTPanda'},user:{id:'AQID',name:'a',displayName:'a'},challenge:CH,authenticatorSelection:{userVerification:'required'},excludeCredentials:[]}});

test('change: begin then passkey then finish with exact bound body and bearer',async()=>{
  const s=setup({reply:p=>p.endsWith('/begin')?{body:ceremony()}:{body:{revoked:'passkey'}}});
  assert.equal(await s.bridge.change('passkey-revoke','k1'),'ok');
  assert.deepEqual(s.calls.map(c=>c.path),['/v1/manage/recovery/begin','/v1/manage/recovery/finish']);
  assert.deepEqual(s.calls[0].body,{kind:'passkey-revoke',target:'k1'});
  assert.equal(s.calls[1].body.kind,'passkey-revoke');assert.equal(s.calls[1].body.target,'k1');assert.equal(s.calls[1].body.token,TOK);assert.ok(s.calls[1].body.response.response.signature);
  for(const c of s.calls){assert.equal(c.opts.headers.Authorization,'Bearer '+ACCESS);assert.equal(c.opts.credentials,'omit');}
});
test('change: enabling needs the accepted warning; unknown kinds and signed-out never call',async()=>{
  const s=setup();await assert.equal(await s.bridge.change('email-escape-on'),'refused');await assert.equal(await s.bridge.change('wipe-all'),'refused');await assert.equal(await s.bridge.change('session-revoke',''),'refused');
  const out=setup({signed:false});await assert.equal(await out.bridge.change('email-escape-off'),'refused');await assert.rejects(out.bridge.status());
  assert.equal(s.calls.length+out.calls.length,0);
  const ok=setup({reply:p=>p.endsWith('/begin')?{body:ceremony()}:{body:{}}});await ok.bridge.change('email-escape-on','',true);assert.equal(ok.calls[0].body.warningAccepted,true);
});
test('change: cancelled or invalid passkey step never reaches finish',async()=>{
  const c=setup({get:async()=>null,reply:()=>({body:ceremony()})});await assert.equal(await c.bridge.change('email-escape-off'),'refused');assert.equal(c.calls.length,1);
  const bad=setup({reply:()=>({body:{...ceremony(),options:{...ceremony().options,rpId:'evil.example'}}})});await assert.equal(await bad.bridge.change('email-escape-off'),'refused');assert.equal(bad.calls.length,1);
});
test('change: server refusal rejects',async()=>{const s=setup({reply:p=>p.endsWith('/begin')?{body:ceremony()}:{status:403,body:{error:'reauthenticate'}}});await assert.equal(await s.bridge.change('email-escape-off'),'refused');});
test('start stores only email+random binding; verify reuses it once and drops it',async()=>{
  const s=setup({reply:p=>p.endsWith('/verify')?{body:{status:'waiting',availableAt:1900000000000}}:{body:{status:'accepted'}}});
  await s.bridge.start(' Me@Example.com ');
  const sent=s.calls[0].body;assert.equal(sent.email,'me@example.com');assert.ok(sent.binding.length>=43);assert.equal(s.calls[0].path,'/auth/recovery/email/request');assert.equal(s.calls[0].opts.headers.Authorization,undefined);
  const stored=[...s.store.values()].join('');assert.ok(!stored.includes('code'));
  const at=await s.bridge.verify('me@example.com','abcd efgh');assert.equal(at,1900000000000);
  assert.equal(s.calls[1].body.binding,sent.binding);assert.equal(s.calls[1].body.code,'ABCDEFGH');assert.equal(s.store.size,0);
  await assert.rejects(s.bridge.verify('me@example.com','ABCDEFGH'));
});
test('verify: other email, expired binding, bad code format or non-waiting reply fail',async()=>{
  const s=setup({reply:()=>({body:{status:'accepted'}})});await s.bridge.start('me@example.com');
  await assert.rejects(s.bridge.verify('other@example.com','ABCDEFGH'));await assert.rejects(s.bridge.verify('me@example.com','abc'));
  await assert.rejects(s.bridge.verify('me@example.com','ABCDEFGH'));
  const key=[...s.store.keys()][0],v=JSON.parse(s.store.get(key));v.at=Date.now()-29*60000;s.store.set(key,JSON.stringify(v));
  v.at=Date.now()-31*60000;s.store.set(key,JSON.stringify(v));
  await assert.rejects(s.bridge.verify('me@example.com','ABCDEFGH'));
});
test('a new start replaces the binding so an older code cannot be used',async()=>{
  const s=setup();await s.bridge.start('me@example.com');const first=s.calls[0].body.binding;await s.bridge.start('me@example.com');assert.notEqual(s.calls[1].body.binding,first);
});
test('complete: fresh binding per phase, new passkey created, no session, nothing secret stored',async()=>{
  const s=setup({reply:p=>p.endsWith('/complete-code')?{body:{status:'accepted'}}:p.endsWith('/complete-begin')?{body:{grant:TOK,ceremony:regCeremony()}}:{body:{status:'completed',signIn:'with the new passkey'}}});
  await s.bridge.sendCompletionCode('me@example.com');
  assert.ok(s.store.has('otpanda.recovery.binding.v1.complete'));assert.ok(![...s.store.keys()].some(k=>k.endsWith('request')));
  await s.bridge.complete('me@example.com','abcdefgh');
  assert.deepEqual(s.calls.map(c=>c.path),['/auth/recovery/email/complete-code','/auth/recovery/email/complete-begin','/auth/recovery/email/complete-finish']);
  assert.equal(s.calls[1].body.binding,s.calls[0].body.binding);assert.equal(s.calls[2].body.grant,TOK);assert.equal(s.calls[2].body.token,TOK);assert.ok(s.calls[2].body.response.response.attestationObject);
  assert.equal(s.store.size,0);for(const c of s.calls)assert.equal(c.opts.headers.Authorization,undefined);
});
test('complete: refused begin, bad ceremony or cancelled passkey never finishes; code is spent',async()=>{
  const refused=setup({reply:p=>p.endsWith('/complete-begin')?{status:403,body:{error:'unavailable'}}:{body:{status:'accepted'}}});await refused.bridge.sendCompletionCode('me@example.com');await assert.equal(await refused.bridge.complete('me@example.com','ABCDEFGH'),'refused');assert.equal(refused.calls.length,2);
  const cancelled=setup({create:async()=>null,reply:p=>p.endsWith('/complete-begin')?{body:{grant:TOK,ceremony:regCeremony()}}:{body:{status:'accepted'}}});await cancelled.bridge.sendCompletionCode('me@example.com');await assert.equal(await cancelled.bridge.complete('me@example.com','ABCDEFGH'),'refused');assert.equal(cancelled.calls.length,2);assert.equal(cancelled.store.size,0);
  const bad=setup({reply:p=>p.endsWith('/complete-begin')?{body:{grant:TOK,ceremony:{...regCeremony(),options:{...regCeremony().options,rp:{id:'evil.example',name:'OTPanda'}}}}}:{body:{status:'accepted'}}});await bad.bridge.sendCompletionCode('me@example.com');await assert.equal(await bad.bridge.complete('me@example.com','ABCDEFGH'),'refused');assert.equal(bad.calls.length,2);
});
test('cancelRequest posts only the id with the bearer',async()=>{const s=setup();await s.bridge.cancelRequest('rq1');assert.deepEqual(s.calls[0].body,{requestId:'rq1'});assert.equal(s.calls[0].opts.headers.Authorization,'Bearer '+ACCESS);await assert.equal(await s.bridge.cancelRequest(''),'refused');});
test('bootstrap hands the factory narrow capabilities and exposes only the frozen bridge',async()=>{
  const boot=fs.readFileSync('tool/session-bootstrap.js','utf8');let caps;
  const loc={origin:'https://otpanda.github.io',pathname:'/app/',search:'',hash:'',assign(){}};
  const ctx={localStorage:{getItem:()=>null,setItem(){},removeItem(){}},location:loc,history:{replaceState(){}},sessionStorage:{getItem:()=>null,setItem(){},removeItem(){}},fetch:async()=>{throw Error('no network')},URL,URLSearchParams,TextEncoder,TextDecoder,Uint8Array,atob:s=>Buffer.from(s,'base64').toString('binary'),btoa:s=>Buffer.from(s,'binary').toString('base64'),crypto:require('node:crypto').webcrypto,navigator:{credentials:{}},
    OTPandaRecoveryFactory:c=>{caps=c;return{status:async()=>'{}'}}};
  vm.createContext(ctx);vm.runInContext(boot,ctx);
  assert.deepEqual(Object.keys(caps).sort(),['access','api','credentials','decode','encode','fetchImpl','generation','random','readBounded','storage']);
  assert.equal(caps.access(),undefined);
  assert.ok(Object.isFrozen(ctx.OTPandaSession.recovery));
  assert.equal(typeof ctx.OTPandaSession.recovery.status,'function');
  const bare={...ctx};delete bare.OTPandaRecoveryFactory;const c2={...bare};vm.createContext(c2);
  vm.runInContext(boot,c2);assert.equal(c2.OTPandaSession.recovery,undefined);
});

test('a live code stays usable for its full 30 minutes',async()=>{
  const s=setup({reply:p=>p.endsWith('/verify')?{body:{status:'waiting',availableAt:1900000000000}}:{body:{status:'accepted'}}});
  await s.bridge.start('me@example.com');const key=[...s.store.keys()][0],v=JSON.parse(s.store.get(key));v.at=Date.now()-29*60000;s.store.set(key,JSON.stringify(v));
  assert.equal(await s.bridge.verify('me@example.com','ABCDEFGH'),1900000000000);
});
function failFinal(path){return {get:undefined};}
test('dropped or unreadable response on the committing request is unknown, not refused',async()=>{
  for(const mode of ['throw','500','408','badbody']){
    const s=setup({reply:(p)=>{if(p.endsWith('/begin'))return{body:ceremony()};if(mode==='throw')throw Error('network');if(mode==='500')return{status:500,body:{}};if(mode==='408')return{status:408,body:{}};return{body:undefined};}});
    assert.equal(await s.bridge.change('email-escape-off'),'unknown',mode);
  }
  const c=setup({reply:()=>{throw Error('network')}});assert.equal(await c.bridge.cancelRequest('rq'),'unknown');
  const done=setup({reply:p=>{if(p.endsWith('/complete-code'))return{body:{status:'accepted'}};if(p.endsWith('/complete-begin'))return{body:{grant:TOK,ceremony:regCeremony()}};throw Error('network after server success');}});
  await done.bridge.sendCompletionCode('me@example.com');assert.equal(await done.bridge.complete('me@example.com','ABCDEFGH'),'unknown');
  const odd=setup({reply:p=>p.endsWith('/complete-code')?{body:{status:'accepted'}}:p.endsWith('/complete-begin')?{body:{grant:TOK,ceremony:regCeremony()}}:{body:{status:'something-else'}}});
  await odd.bridge.sendCompletionCode('me@example.com');assert.equal(await odd.bridge.complete('me@example.com','ABCDEFGH'),'unknown');
});
test('definite refusals and pre-send failures stay refused',async()=>{
  const s=setup({reply:p=>p.endsWith('/begin')?{body:ceremony()}:{status:403,body:{}}});assert.equal(await s.bridge.change('email-escape-off'),'refused');
  const t=setup({reply:p=>p.endsWith('/begin')?{body:ceremony()}:{status:429,body:{}}});assert.equal(await t.bridge.change('email-escape-off'),'refused');
  const f=setup({reply:p=>p.endsWith('/complete-code')?{body:{status:'accepted'}}:p.endsWith('/complete-begin')?{body:{grant:TOK,ceremony:regCeremony()}}:{status:403,body:{}}});
  await f.bridge.sendCompletionCode('me@example.com');assert.equal(await f.bridge.complete('me@example.com','ABCDEFGH'),'refused');
});

test('legacy Security client approval controls use the same unavailable capability gate',()=>{
 const source=fs.readFileSync('lib/browser_account_page.dart','utf8');
 assert(source.includes('if (otherClient && !clientApprovalAvailable) return;'));
 assert(source.includes('if (clientApprovalAvailable && settingChange != null)'));
 assert.equal((source.match(/if \(clientApprovalAvailable\)/g)||[]).length,3);
 assert(!source.includes('New devices need a passkey or approval from another signed-in device.'));
});
