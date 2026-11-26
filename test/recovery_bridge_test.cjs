const {test}=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');
const src=fs.readFileSync('tool/recovery-bridge.js','utf8');
const timers=()=>({setTimeout:(f,ms)=>{const t=setTimeout(f,ms);if(ms>=10000)t.unref();return t},clearTimeout,AbortController});
const TOK='otpda_'+'a'.repeat(55),ACCESS='otpda_'+'b'.repeat(55),CH='A'.repeat(43);
const encode=b=>Buffer.from(b).toString('base64url'),decode=v=>new Uint8Array(Buffer.from(v,'base64url'));
function setup({signed=true,get,create,reply}={}){
  const calls=[],store=new Map();let n=0;
  const storage={getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>store.set(k,v),removeItem:k=>store.delete(k)};
  const ctx=timers();vm.createContext(ctx);vm.runInContext(src,ctx);
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
const SKEW=[['device 1 s behind',121000,true],['device 30 s behind',150000,true],['device 30 s ahead',90000,true],['device 300 s behind',420000,true],['device 130 s ahead',-10000,false],['already expired',-1,false],['beyond tolerance',420500,false]];
test('assertion challenge: clock skew tolerated up to TTL+300 s, prompt timeout capped at 120 s, otherwise fails closed',async()=>{
  for(const [name,ahead,ok] of SKEW){
    let timeout;const s=setup({get:async o=>{timeout=o.publicKey.timeout;return cred();},reply:p=>p.endsWith('/begin')?{body:{...ceremony(),expiresAt:Date.now()+ahead}}:{body:{revoked:'passkey'}}});
    const r=await s.bridge.change('email-escape-off');
    assert.equal(r,ok?'ok':'refused',name);assert.equal(s.calls.length,ok?2:1,name);
    if(ok){assert.ok(timeout>0&&timeout<=120000,name);assert.ok(Math.abs(timeout-Math.min(120000,ahead))<=500,name+' timeout');}
  }
});
test('registration challenge: same skew tolerance and 120 s prompt cap',async()=>{
  for(const [name,ahead,ok] of SKEW){
    let timeout;const s=setup({create:async o=>{timeout=o.publicKey.timeout;return reg();},reply:p=>p.endsWith('/complete-code')?{body:{status:'accepted'}}:p.endsWith('/complete-begin')?{body:{grant:TOK,ceremony:{...regCeremony(),expiresAt:Date.now()+ahead}}}:{body:{status:'completed',signIn:'with the new passkey'}}});
    await s.bridge.sendCompletionCode('me@example.com');await s.bridge.complete('me@example.com','abcdefgh').catch(()=>{});
    assert.equal(s.calls.some(c=>c.path.endsWith('/complete-finish')),ok,name);
    if(ok)assert.ok(Math.abs(timeout-Math.min(120000,ahead))<=500,name+' timeout');
  }
});
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

test('change: google-unlink is a known kind that sends no target and finishes after the passkey step',async()=>{
  const s=setup({reply:p=>p.endsWith('/begin')?{body:ceremony()}:{body:{revoked:'google'}}});
  assert.equal(await s.bridge.change('google-unlink'),'ok');
  assert.deepEqual(s.calls.map(c=>c.path.split('/').pop()),['begin','finish']);
  assert.equal(s.calls[0].body.kind,'google-unlink');assert.ok(!('target' in s.calls[0].body));assert.ok(!('warningAccepted' in s.calls[0].body));
});

test('renamePasskey posts exact id and normalized label with the bearer and no passkey check',async()=>{
  const s=setup({reply:()=>({body:{ok:true}})});
  assert.equal(await s.bridge.renamePasskey('k1','  Cafe\u0301 key  '),'ok');
  assert.deepEqual(s.calls.map(c=>c.path),['/v1/manage/passkey/rename']);
  assert.deepEqual(s.calls[0].body,{credentialId:'k1',label:'Caf\u00e9 key'});
  assert.equal(s.calls[0].opts.headers.Authorization,'Bearer '+ACCESS);assert.equal(s.calls[0].opts.credentials,'omit');
  assert.equal(await s.bridge.renamePasskey('k1',null),'ok');assert.deepEqual(s.calls[1].body,{credentialId:'k1',label:null});
  assert.equal(await s.bridge.renamePasskey('k1',''),'ok');assert.deepEqual(s.calls[2].body,{credentialId:'k1',label:null});
});
test('renamePasskey refuses bad input without a request and treats a bad reply as unknown',async()=>{
  const s=setup({reply:()=>({body:{ok:true}})});
  for(const [id,label] of [['','x'],[7,'x'],['k','a'.repeat(41)],['k','bad\u0007'],['k',5],['k','   x']]){
    const before=s.calls.length;const r=await s.bridge.renamePasskey(id,label);
    if(id==='k'&&label==='   x')assert.equal(r,'ok');else{assert.equal(r,'refused');assert.equal(s.calls.length,before);}
  }
  const u=setup();assert.equal(await u.bridge.renamePasskey('k','x'),'unknown');
  const n=setup({reply:()=>{throw Error('network')}});assert.equal(await n.bridge.renamePasskey('k','x'),'unknown');
  const nosign=setup({signed:false});assert.equal(await nosign.bridge.renamePasskey('k','x'),'refused');
});

const UA_FF='Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0';
const UA_CH='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
const UA_ED=UA_CH+' Edg/130.0.0.0';
const UA_SF='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
test('detectDevice maps to closed enums only',()=>{
  const ctx=timers();vm.createContext(ctx);vm.runInContext(src,ctx);const d=ctx.OTPandaDetectDevice;
  assert.deepEqual({...d({userAgent:UA_FF})},{browser:'firefox',os:'linux'});
  assert.deepEqual({...d({userAgent:UA_CH})},{browser:'chrome',os:'windows'});
  assert.deepEqual({...d({userAgent:UA_ED})},{browser:'edge',os:'windows'});
  assert.deepEqual({...d({userAgent:UA_SF})},{browser:'safari',os:'mac'});
  assert.deepEqual({...d({userAgent:'x',userAgentData:{brands:[{brand:'Google Chrome',version:'1'}],platform:'Android'}})},{browser:'chrome',os:'android'});
  assert.deepEqual({...d({userAgent:'Mozilla/5.0 (Linux; Android 14; Pixel 8a) Chrome/130 Mobile Safari/537.36'})},{browser:'chrome',os:'android'});
  assert.deepEqual({...d(undefined)},{browser:'other',os:'other'});
});
test('status describes the session once per generation and value, then reads status; failure is ignored',async()=>{
  const s=setup({reply:(p)=>p.endsWith('/describe')?{body:{ok:true}}:{body:{passkeys:[],sessions:[]}}});
  await s.bridge.status();await s.bridge.status();
  assert.deepEqual(s.calls.map(c=>c.path),['/v1/manage/session/describe','/v1/manage/recovery/status','/v1/manage/recovery/status']);
  const b=s.calls[0].body;assert.deepEqual(Object.keys(b).sort(),['browser','name','os']);assert.equal(b.name,null);
  assert.equal(s.calls[0].opts.headers.Authorization,'Bearer '+ACCESS);assert.equal(s.calls[0].opts.credentials,'omit');
  const f=setup({reply:(p)=>p.endsWith('/describe')?{status:500,body:{}}:{body:{passkeys:[],sessions:[]}}});
  await f.bridge.status();await f.bridge.status();
  assert.equal(f.calls.filter(c=>c.path.endsWith('/describe')).length,2);
  assert.equal(f.calls.filter(c=>c.path.endsWith('/status')).length,2);
});

test('a describe that never resolves delays status by the short deadline only and is sent once',async()=>{
  const ctx=timers();vm.createContext(ctx);vm.runInContext(src,ctx);
  const calls=[];
  const never=new Promise(()=>{});
  const resp=obj=>({ok:true,status:200,headers:{get:()=>null},body:{getReader(){let s=false;return{async read(){if(s)return{done:true};s=true;return{done:false,value:new TextEncoder().encode(JSON.stringify(obj))}},async cancel(){},releaseLock(){}}}}});
  const bridge=ctx.OTPandaRecoveryFactory({api:'https://api.test',access:()=>ACCESS,generation:()=>1,
    readBounded:async r=>{const {value}=await r.body.getReader().read();return value?new TextDecoder().decode(value):''},
    encode,decode,random:()=>'x',storage:{getItem:()=>null,setItem(){},removeItem(){}},credentials:{},
    fetchImpl:async(url)=>{const path=url.replace('https://api.test','');calls.push(path);if(path.endsWith('/describe'))return never;return resp({passkeys:[],sessions:[]})}});
  const t0=Date.now();
  const a=await bridge.status();const b=await bridge.status();
  assert.ok(a&&b);
  assert.ok(Date.now()-t0<6000);
  assert.equal(calls.filter(p=>p.endsWith('/describe')).length,1);
  assert.equal(calls.filter(p=>p.endsWith('/status')).length,2);
});

test('the 15s deadline settles a describe that ignores abort, so a later status can describe again',async()=>{
  const slow=[];
  const ctx={setTimeout:(f,ms)=>{if(ms>=10000){slow.push(f);return slow.length}return setTimeout(f,1)},clearTimeout:()=>{},AbortController};
  vm.createContext(ctx);vm.runInContext(src,ctx);
  const calls=[];
  const resp=obj=>({ok:true,status:200,headers:{get:()=>null},body:{getReader(){let s=false;return{async read(){if(s)return{done:true};s=true;return{done:false,value:new TextEncoder().encode(JSON.stringify(obj))}},async cancel(){},releaseLock(){}}}}});
  const bridge=ctx.OTPandaRecoveryFactory({api:'https://api.test',access:()=>ACCESS,generation:()=>1,
    readBounded:async r=>{const {value}=await r.body.getReader().read();return value?new TextDecoder().decode(value):''},
    encode,decode,random:()=>'x',storage:{getItem:()=>null,setItem(){},removeItem(){}},credentials:{},
    fetchImpl:async(url)=>{const path=url.replace('https://api.test','');calls.push(path);if(path.endsWith('/describe'))return new Promise(()=>{});return resp({passkeys:[],sessions:[]})}});
  await bridge.status();await bridge.status();
  assert.equal(calls.filter(p=>p.endsWith('/describe')).length,1);
  slow.forEach(f=>f());await new Promise(r=>setTimeout(r,5));
  await bridge.status();
  assert.equal(calls.filter(p=>p.endsWith('/describe')).length,2);
});
