function streaming(r){if(r&&typeof r.text==='function'&&!r.body){r.body={getReader(){let sent=false;return {async read(){if(sent)return {done:true};sent=true;return {done:false,value:new TextEncoder().encode(await r.text())};},async cancel(){},releaseLock(){}};}};}return r;}
const {test}=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');const script=fs.readFileSync('tool/session-bootstrap.js','utf8');
const NOW=1800000000000,token='otpda_'+'a'.repeat(55),state='s'.repeat(43);
function env({hash='',saved,now=NOW,response={access:token,accessExpiresAt:NOW+300000},hint,navigator,fetchImpl,sessionValues=new Map()}={}){let stored=saved,cleaned=false,calls=0;const location={origin:'https://otpanda.github.io',pathname:'/app/',search:'',hash,assign(url){location.assigned=url;}};const hints=new Map(hint?[['otpanda-session-present','yes']]:[]);const context={AbortController,setTimeout,clearTimeout,localStorage:{getItem:k=>hints.get(k),setItem:(k,v)=>hints.set(k,v),removeItem:k=>hints.delete(k)},location,history:{replaceState(){cleaned=true;location.hash='';}},sessionStorage:{getItem(k){return k==='otpanda.restore.tab.v1'?stored:sessionValues.get(k)??null;},removeItem(k){if(k==='otpanda.restore.tab.v1')stored=undefined;else sessionValues.delete(k);},setItem(k,v){if(k==='otpanda.restore.tab.v1')stored=v;else sessionValues.set(k,v);}},fetch:async(url,options)=>{assert.ok(cleaned);assert.equal(options.credentials,'omit');assert.equal(options.redirect,'error');calls++;return {ok:true,text:async()=>JSON.stringify(response)};},URL,URLSearchParams,TextEncoder,TextDecoder,Uint8Array,atob:s=>Buffer.from(s,'base64').toString('binary'),crypto:require('node:crypto').webcrypto,btoa:s=>Buffer.from(s,'binary').toString('base64'),Date:class extends Date{static now(){return now;}}};if(navigator)context.navigator=navigator;if(fetchImpl)context.fetch=fetchImpl;let fetchValue=context.fetch;Object.defineProperty(context,'fetch',{get(){return async(...args)=>streaming(await fetchValue(...args));},set(v){fetchValue=v;},enumerable:true,configurable:true});vm.createContext(context);vm.runInContext(script,context);return {context,get cleaned(){return cleaned;},get stored(){return stored;},get calls(){return calls;}};}
test('callback cleans synchronously before exchange; state consumed and memory access returned',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});assert.ok(e.cleaned);await e.context.OTPandaSession.ready;assert.equal(e.calls,1);assert.equal(e.stored,undefined);assert.equal(e.context.OTPandaSession.status(),'restored');assert.equal(e.context.OTPandaSession.access(),token);e.context.OTPandaSession.clear();assert.equal(e.context.OTPandaSession.access(),undefined);});
test('wrong state duplicates missing pending and future/expired state never exchange',async()=>{for(const change of [{saved:undefined},{hash:'#code='+token+'&state=wrong'},{hash:'#code='+token+'&state='+state+'&state='+state},{now:NOW+300001},{now:NOW-1}]){const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),...change});assert.ok(e.cleaned);await e.context.OTPandaSession.ready;assert.equal(e.calls,0);assert.equal(e.context.OTPandaSession.status(),'sign-in-required');}});
test('invalid response never becomes access; secrets absent from storage',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),response:{access:token,refresh:'bad',accessExpiresAt:NOW+300000}});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.stored,undefined);});
test('logout during exchange cannot resurrect a late access response',async()=>{let release;const e=env({hash:''});const loc=e.context.location;loc.hash='#code='+token+'&state='+state;let stored=JSON.stringify({state,verifier:'v'.repeat(43),created:NOW});e.context.sessionStorage.getItem=()=>stored;e.context.sessionStorage.removeItem=()=>{stored=undefined;};e.context.fetch=()=>new Promise(resolve=>{release=()=>resolve({ok:true,text:async()=>JSON.stringify({access:token,accessExpiresAt:NOW+300000})});});const other=vm.createContext({...e.context,OTPandaSession:undefined});vm.runInContext(script,other);while(!release)await new Promise(r=>setImmediate(r));other.OTPandaSession.clear();release();await other.OTPandaSession.ready;assert.equal(other.OTPandaSession.access(),undefined);assert.equal(other.OTPandaSession.status(),'idle');});

test('clear while PKCE is computing cannot start a late restore navigation',async()=>{const e=env();let release;const native=e.context.crypto;e.context.crypto={getRandomValues:v=>native.getRandomValues(v),subtle:{digest:()=>new Promise(r=>{release=r;})}};const pending=e.context.OTPandaSession.start();e.context.OTPandaSession.clear();release(new Uint8Array(32).buffer);await pending;assert.equal(e.context.location.assigned,undefined);assert.equal(e.stored,undefined);});
test('newer start supersedes an older in-flight PKCE computation',async()=>{const e=env();const waiting=[],native=e.context.crypto;e.context.crypto={getRandomValues:v=>native.getRandomValues(v),subtle:{digest:()=>new Promise(r=>waiting.push(r))}};const first=e.context.OTPandaSession.start(),second=e.context.OTPandaSession.start();waiting[1](new Uint8Array(32).buffer);await second;const winner=e.context.location.assigned,saved=e.stored;waiting[0](new Uint8Array(32).buffer);await first;assert.equal(e.context.location.assigned,winner);assert.equal(e.stored,saved);assert.ok(winner.includes('/auth/restore?'));});
function loginEnv(patch={}){const c={token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),timeout:120000,userVerification:'required'},...patch};return env({hash:'#login='+Buffer.from(JSON.stringify(c)).toString('base64url')+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});}
test('login fragment is removed before deliberate passkey prompt; ceremony stays out of storage',async()=>{const e=loginEnv();assert.ok(e.cleaned);await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'passkey-ready');assert.equal(e.calls,0);assert.equal(e.stored,undefined);});
test('wrong RP, weak verification or extra extensions never reach passkey-ready',async()=>{for(const options of [{rpId:'evil.example',challenge:'A'.repeat(43),timeout:120000,userVerification:'required'},{rpId:'otpanda.github.io',challenge:'A'.repeat(43),timeout:120000,userVerification:'preferred'},{rpId:'otpanda.github.io',challenge:'A'.repeat(43),timeout:120000,userVerification:'required',extensions:{appid:'https://evil.example'}}]){const e=loginEnv({options});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'sign-in-required');assert.equal(e.calls,0);}});
function credential(){const b=new Uint8Array([1,2,3]).buffer;return {id:'AQID',rawId:b,type:'public-key',getClientExtensionResults:()=>({}),response:{clientDataJSON:b,authenticatorData:b,signature:b,userHandle:b}};}
test('passkey verification sends no cookies and completion carries only one-use handoff',async()=>{const e=loginEnv();await e.context.OTPandaSession.ready;let calls=0;e.context.navigator={credentials:{get:async options=>{assert.equal(options.publicKey.rpId,'otpanda.github.io');assert.equal(options.publicKey.userVerification,'required');return credential();}}};e.context.fetch=async(url,o)=>{calls++;assert.equal(url,'https://otpanda-api.abrahammurciano.workers.dev/auth/login/verify');assert.equal(o.credentials,'omit');assert.equal(o.redirect,'error');assert.deepEqual(Object.keys(JSON.parse(o.body)).sort(),['response','token']);return {ok:true,text:async()=>JSON.stringify({handoff:token,expiresAt:NOW+60000})};};await e.context.OTPandaSession.passkey();assert.equal(calls,1);assert.equal(e.context.OTPandaSession.status(),'completing');assert.ok(e.context.location.assigned.includes('/auth/login/complete#handoff='));assert.ok(!e.stored.includes(token));});
test('clear during OS prompt prevents late assertion send or completion navigation',async()=>{const e=loginEnv();await e.context.OTPandaSession.ready;let release;e.context.navigator={credentials:{get:()=>new Promise(r=>release=r)}};const pending=e.context.OTPandaSession.passkey();e.context.OTPandaSession.clear();release(credential());await pending;assert.equal(e.context.location.assigned,undefined);assert.equal(e.calls,0);assert.equal(e.stored,undefined);});
test('login start creates only tab PKCE state and canonical navigation',async()=>{const e=env();await e.context.OTPandaSession.start('login');assert.ok(e.context.location.assigned.startsWith('https://otpanda-api.abrahammurciano.workers.dev/auth/login/start?'));assert.ok(!e.stored.includes('refresh'));});
test('access polling before and during passkey prompt never cancels a pending ceremony',async()=>{const e=loginEnv();await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.context.OTPandaSession.status(),'passkey-ready');let release;e.context.navigator={credentials:{get:()=>new Promise(r=>release=r)}};let sent=0;e.context.fetch=async()=>{sent++;return {ok:true,text:async()=>JSON.stringify({handoff:token,expiresAt:NOW+60000})};};const pending=e.context.OTPandaSession.passkey();assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.context.OTPandaSession.status(),'authenticating');release(credential());await pending;assert.equal(sent,1);assert.equal(e.context.OTPandaSession.status(),'completing');});
test('access polling during exchange leaves callback generation intact',async()=>{let release;const e=env();e.context.location.hash='#code='+token+'&state='+state;e.context.sessionStorage.getItem=()=>JSON.stringify({state,verifier:'v'.repeat(43),created:NOW});e.context.fetch=()=>new Promise(r=>release=()=>r({ok:true,text:async()=>JSON.stringify({access:token,accessExpiresAt:NOW+300000})}));const other=vm.createContext({...e.context,OTPandaSession:undefined});vm.runInContext(script,other);assert.equal(other.OTPandaSession.access(),undefined);assert.equal(other.OTPandaSession.status(),'restoring');while(!release)await new Promise(r=>setImmediate(r));release();await other.OTPandaSession.ready;assert.equal(other.OTPandaSession.access(),token);assert.equal(other.OTPandaSession.status(),'restored');});
test('access expiry pauses without pretending the refresh session ended',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.access(),token);e.context.Date={now:()=>NOW+300000};assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.context.OTPandaSession.status(),'session-paused');});
test('read transport allows only management GET with memory bearer and no cookies',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;e.context.fetch=async(url,o)=>{assert.equal(url,'https://otpanda-api.abrahammurciano.workers.dev/v1/manage/entries');assert.equal(o.method,'GET');assert.equal(o.credentials,'omit');assert.equal(o.redirect,'error');assert.equal(o.cache,'no-store');assert.equal(o.headers.Authorization,'Bearer '+token);return {status:200,text:async()=>'{}'};};assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,200);await assert.rejects(e.context.OTPandaSession.read('/v1/manage/tokens'));});
test('read401 clears invalid access but restores using existing first-party cookie',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;e.context.fetch=async()=>({status:401,text:async()=>'{}'});assert.equal((await e.context.OTPandaSession.read('/v1/manage/session')).status,503);assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.context.OTPandaSession.status(),'restoring');assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');assert.ok(e.context.location.assigned.includes('/auth/restore?'));});
test('late read after clear cannot expose its response',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;let release;e.context.fetch=()=>new Promise(r=>release=()=>r({status:200,text:async()=>'{"secret":"synthetic"}'}));const read=e.context.OTPandaSession.read('/v1/manage/active-codes');while(!release)await new Promise(r=>setImmediate(r));e.context.OTPandaSession.clear();release();assert.equal((await read).body,'{}');});
test('no-access read does not cancel pending passkey work',async()=>{const e=loginEnv();await e.context.OTPandaSession.ready;assert.equal((await e.context.OTPandaSession.read('/v1/manage/session')).status,401);assert.equal(e.context.OTPandaSession.status(),'passkey-ready');e.context.navigator={credentials:{get:async()=>null}};await e.context.OTPandaSession.passkey();assert.equal(e.context.OTPandaSession.status(),'sign-in-required');});

test('server logout cancels pending work and navigates only to first-party confirmation',async()=>{const e=loginEnv();await e.context.OTPandaSession.ready;e.context.OTPandaSession.logout();assert.equal(e.context.location.assigned,'https://otpanda-api.abrahammurciano.workers.dev/auth/device/logout');assert.equal(e.context.OTPandaSession.status(),'idle');assert.equal(e.stored,undefined);await assert.rejects(e.context.OTPandaSession.passkey());});

test('logout rejects late read responses',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;let release;e.context.fetch=()=>new Promise(r=>release=()=>r({status:200,text:async()=>'sensitive'}));const read=e.context.OTPandaSession.read('/v1/manage/active-codes');while(!release)await new Promise(r=>setImmediate(r));e.context.OTPandaSession.logout();release();assert.equal((await read).body,'{}');assert.equal(e.context.OTPandaSession.access(),undefined);});
test('read byte ceiling cancels stream before buffering the complete response',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;let reads=0,cancelled=false,released=false;e.context.fetch=async()=>({status:200,body:{getReader(){return {async read(){reads++;return {done:false,value:new Uint8Array(300000)};},async cancel(){cancelled=true;},releaseLock(){released=true;}};}}});await assert.rejects(e.context.OTPandaSession.read('/v1/manage/entries'));assert.equal(reads,2);assert.equal(cancelled,true);assert.equal(released,true);});
test('oversized content length rejects before opening response body',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;let opened=false;e.context.fetch=async()=>({status:200,headers:{get:()=> '524289'},body:{getReader(){opened=true;throw Error();}}});await assert.rejects(e.context.OTPandaSession.read('/v1/manage/entries'));assert.equal(opened,false);});
test('invalid UTF8 denies and byte count does not use decoded character length',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;let cancelled=false;e.context.fetch=async()=>({status:200,body:{getReader(){return {async read(){return {done:false,value:new Uint8Array([255])};},async cancel(){cancelled=true;},releaseLock(){}};}}});await assert.rejects(e.context.OTPandaSession.read('/v1/manage/entries'));assert.equal(cancelled,true);});

test('private inbox read allowlist is exact and retains GET/no cookies',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;let reads=0;e.context.fetch=async(url,o)=>{reads++;assert.ok(['/v1/manage/sources','/v1/manage/unassigned'].some(p=>url==='https://otpanda-api.abrahammurciano.workers.dev'+p));assert.equal(o.method,'GET');assert.equal(o.credentials,'omit');assert.equal(o.redirect,'error');assert.equal(o.cache,'no-store');assert.equal(o.headers.Authorization,'Bearer '+token);return {status:200,text:async()=>'{}'};};for(const p of ['/v1/manage/sources','/v1/manage/unassigned'])assert.equal((await e.context.OTPandaSession.read(p)).status,200);for(const p of ['/v1/manage/sources?all=1','/v1/manage/unassigned/assign','/v1/manage/sources/phone','https://other.test/v1/manage/unassigned'])await assert.rejects(e.context.OTPandaSession.read(p));assert.equal(reads,2);});
test('organization transport exact methods, payload bounds and no-cookie bearer requests',async()=>{const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;const calls=[];e.context.fetch=async(url,o)=>{calls.push({url,o});return {status:200,text:async()=>'{}'};};await e.context.OTPandaSession.organize('GET','');await e.context.OTPandaSession.organize('PUT','{"revision":0,"document":{"tags":[],"entries":[]}}');await e.context.OTPandaSession.copied('entry',NOW);assert.equal(calls.length,3);for(const c of calls){assert.equal(c.o.credentials,'omit');assert.equal(c.o.redirect,'error');assert.equal(c.o.cache,'no-store');assert.equal(c.o.headers.Authorization,'Bearer '+token);}assert.equal(calls[0].url,'https://otpanda-api.abrahammurciano.workers.dev/v1/manage/organization');assert.equal(calls[0].o.method,'GET');assert.equal(calls[1].o.method,'PUT');assert.equal(calls[2].url,'https://otpanda-api.abrahammurciano.workers.dev/v1/manage/organization-copy');assert.equal(calls[2].o.method,'POST');const receipt=JSON.parse(calls[2].o.body);assert.equal(receipt.entryId,'entry');assert.equal(receipt.createdAt,NOW);assert.match(receipt.receiptId,/^[A-Za-z0-9_-]{43}$/);await assert.rejects(e.context.OTPandaSession.organize('DELETE',''));await assert.rejects(e.context.OTPandaSession.organize('GET','{}'));await assert.rejects(e.context.OTPandaSession.organize('PUT','x'.repeat(131073)));assert.equal(calls.length,3);});
function signupEnv(patch={}){const c={token,expiresAt:NOW+120000,options:{rp:{id:'otpanda.github.io',name:'OTPanda'},user:{id:'YWNjb3VudA',name:'a@example.com',displayName:'a@example.com'},challenge:'A'.repeat(43),pubKeyCredParams:[{type:'public-key',alg:-7},{type:'public-key',alg:-257}],timeout:120000,attestation:'none',excludeCredentials:[],authenticatorSelection:{residentKey:'required',userVerification:'required'},extensions:{credProps:true}},...patch};return env({hash:'#signup='+Buffer.from(JSON.stringify(c)).toString('base64url')+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});}
test('signup fragment clears synchronously and waits for explicit create action',async()=>{const e=signupEnv();assert.ok(e.cleaned);await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'signup-ready');assert.equal(e.calls,0);assert.equal(e.stored,undefined);});
test('signup requires exact RP and mandatory resident verified credential',async()=>{for(const changes of [{rp:{id:'evil.test',name:'OTPanda'}},{authenticatorSelection:{residentKey:'preferred',userVerification:'required'}},{attestation:'direct'},{extensions:{appid:'evil'}}]){const good=signupEnv();await good.context.OTPandaSession.ready;const c={token,expiresAt:NOW+120000,options:{rp:{id:'otpanda.github.io',name:'OTPanda'},user:{id:'YWNjb3VudA',name:'a@example.com',displayName:'a@example.com'},challenge:'A'.repeat(43),pubKeyCredParams:[{type:'public-key',alg:-7},{type:'public-key',alg:-257}],timeout:120000,attestation:'none',excludeCredentials:[],authenticatorSelection:{residentKey:'required',userVerification:'required'},...changes}};const e=signupEnv(c);await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'sign-in-required');}});
test('explicit signup creates credential then verifies without cookies and completes existing protocol',async()=>{const e=signupEnv();await e.context.OTPandaSession.ready;const bytes=new Uint8Array([1,2,3]).buffer;e.context.navigator={credentials:{create:async({publicKey:o})=>{assert.equal(o.rp.id,'otpanda.github.io');assert.equal(o.authenticatorSelection.userVerification,'required');return{id:'AQID',rawId:bytes,type:'public-key',getClientExtensionResults:()=>({credProps:{rk:true}}),response:{clientDataJSON:bytes,attestationObject:bytes,getTransports:()=>['internal']}};}}};e.context.fetch=async(url,o)=>{assert.equal(url,'https://otpanda-api.abrahammurciano.workers.dev/auth/signup/verify');assert.equal(o.credentials,'omit');assert.ok(JSON.parse(o.body).response.response.attestationObject);return{ok:true,text:async()=>JSON.stringify({handoff:token,expiresAt:NOW+60000})};};await e.context.OTPandaSession.passkey();assert.equal(e.context.OTPandaSession.status(),'completing');assert.ok(e.context.location.assigned.includes('/auth/login/complete#handoff='));});
test('signup navigation uses top-level API start and no mailproof in app storage',async()=>{const e=env();await e.context.OTPandaSession.start('signup');assert.ok(e.context.location.assigned.startsWith('https://otpanda-api.abrahammurciano.workers.dev/auth/signup/start?'));assert.deepEqual(Object.keys(JSON.parse(e.stored)).sort(),['created','state','verifier']);});
test('older authenticator API without getTransports still verifies with an empty optional list',async()=>{const e=signupEnv();await e.context.OTPandaSession.ready;const bytes=new Uint8Array([1]).buffer;e.context.navigator={credentials:{create:async()=>({id:'AQ',rawId:bytes,type:'public-key',getClientExtensionResults:()=>({}),response:{clientDataJSON:bytes,attestationObject:bytes}})}};e.context.fetch=async(url,o)=>{assert.deepEqual(JSON.parse(o.body).response.response.transports,[]);return{ok:true,text:async()=>JSON.stringify({handoff:token,expiresAt:NOW+60000})};};await e.context.OTPandaSession.passkey();assert.equal(e.context.OTPandaSession.status(),'completing');});
test('signup cancellation exposes explicit retry status without keeping ceremony secret',async()=>{const e=signupEnv();await e.context.OTPandaSession.ready;e.context.navigator={credentials:{create:async()=>{throw Error('cancelled');}}};await e.context.OTPandaSession.passkey();assert.equal(e.context.OTPandaSession.status(),'signup-retry-required');assert.equal(e.stored,undefined);});
test('clock skew exposes check-clock-or-restart instead of silently retrying enrollment',async()=>{const e=signupEnv({expiresAt:NOW+130000});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'check-clock-or-restart');assert.equal(e.calls,0);});

async function assignmentEnv(){
 const {bundleAssignment}=await import('../tool/build-assignment-host.mjs');
 const e=env();const context={...e.context,OTPandaSession:undefined};
 context.location.hash='#code='+token+'&state='+state;
 context.sessionStorage.getItem=()=>JSON.stringify({state,verifier:'v'.repeat(43),created:NOW});
 vm.createContext(context);vm.runInContext(await bundleAssignment(),context);vm.runInContext(script,context);
 await context.OTPandaSession.ready;return context;
}
const assignmentBegin=()=>({intentId:'intent',token:'ceremony-secret',action:JSON.stringify(['otpanda-assignment',1,'intent','owner','device',1,'source','event','entry',0,'hash',0,0,2,1,true]),expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),timeout:120000,userVerification:'required',allowCredentials:[{type:'public-key',id:'AQID'}]},summary:{operation:'assign-code',entryId:'entry',label:'Fixture',accountName:null,serviceId:'fixture',activeRecipients:2,automationRecipients:1,irreversible:true}});
test('opt-in host summary excludes ceremony, no prompt before confirm, one finish',async()=>{
 const c=await assignmentEnv();let prompts=0,writes=0;c.navigator={credentials:{get:async()=>{prompts++;return credential();}}};
 c.fetch=async(url,o)=>streaming(await (async()=>{assert.equal(o.headers.Authorization,'Bearer '+token);assert.equal(o.credentials,'omit');assert.equal(o.redirect,'error');if(url.endsWith('/begin'))return{status:200,text:async()=>JSON.stringify(assignmentBegin())};if(url.endsWith('/finish')){writes++;return{status:200,text:async()=>JSON.stringify({status:'assigned'})};}throw Error('Unexpected request');})());
 const summary=JSON.parse(await c.OTPandaSession.assignmentPrepare(JSON.stringify({sourceId:'source',eventId:'event',entryId:'entry'})));
 assert.equal(summary.activeRecipients,2);assert.equal(summary.token,undefined);assert.equal(prompts,0);assert.equal(writes,0);
 assert.equal(await c.OTPandaSession.assignmentConfirm(),'assigned');assert.equal(prompts,1);assert.equal(writes,1);
 c.OTPandaSession.clear();assert.equal(c.OTPandaSession.assignmentState(),'idle');
});
test('default host assignment unsupported and cannot initiate a request',async()=>{const e=env();assert.equal(e.context.OTPandaSession.assignmentState(),'unsupported');await assert.rejects(()=>e.context.OTPandaSession.assignmentPrepare('{}'));assert.equal(e.calls,0);});
test('opt-in session logout during assignment proof prevents late finish',async()=>{
 const c=await assignmentEnv();let release,writes=0;c.navigator={credentials:{get:()=>new Promise(r=>release=r)}};
 c.fetch=async(url)=>streaming({status:200,text:async()=>{if(url.endsWith('/begin'))return JSON.stringify(assignmentBegin());writes++;return JSON.stringify({status:'assigned'});}});
 await c.OTPandaSession.assignmentPrepare(JSON.stringify({sourceId:'source',eventId:'event',entryId:'entry'}));
 const result=c.OTPandaSession.assignmentConfirm();c.OTPandaSession.logout();release(credential());await result;
 assert.equal(writes,0);assert.equal(c.OTPandaSession.assignmentState(),'idle');assert.equal(c.OTPandaSession.access(),undefined);
});
test('opt-in session logout after submitted finish suppresses late outcome only',async()=>{
 const c=await assignmentEnv();let release,writes=0;c.navigator={credentials:{get:async()=>credential()}};
 c.fetch=async(url)=>{if(url.endsWith('/begin'))return streaming({status:200,text:async()=>JSON.stringify(assignmentBegin())});writes++;return new Promise(r=>release=()=>r(streaming({status:200,text:async()=>JSON.stringify({status:'assigned'})})));};
 await c.OTPandaSession.assignmentPrepare(JSON.stringify({sourceId:'source',eventId:'event',entryId:'entry'}));
 const result=c.OTPandaSession.assignmentConfirm();while(!release)await new Promise(r=>setImmediate(r));c.OTPandaSession.logout();release();await result;
 assert.equal(writes,1);assert.equal(c.OTPandaSession.assignmentState(),'idle');
});

test('app email flow uses fragments for email/proof and stores no proof',async()=>{const e=env();await e.context.OTPandaSession.signupEmail('a@example.com',token);const u=new URL(e.context.location.assigned);assert.equal(u.pathname,'/auth/signup/app');assert.ok(!u.search.includes('example'));assert.ok(u.hash.includes('email_token='));assert.ok(!e.stored.includes(token));assert.equal(JSON.parse(e.stored).email,'a@example.com');});
test('email callback validates state and exposes only app code-entry status',async()=>{const e=env({hash:'#auth=email-sent&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW,email:'a@example.com'})});assert.ok(e.cleaned);await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'email-code');assert.equal(e.context.OTPandaSession.email(),'a@example.com');assert.equal(e.calls,0);assert.equal(e.stored,undefined);});
test('unknown app redirect status and duplicate fields fail closed',async()=>{for(const hash of ['#auth=stolen&state='+state,'#auth=email-sent&auth=restart&state='+state]){const e=env({hash,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'sign-in-required');assert.equal(e.calls,0);}});

test('reload hint restores through first-party navigation only, failed restore clears hint and logout prevents loops',async()=>{const e=env({hint:true});await e.context.OTPandaSession.ready;assert.equal(e.calls,0);assert.match(e.context.location.assigned,/^https:\/\/otpanda-api.*\/auth\/restore\?/);assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(Object.keys(JSON.parse(e.stored)).sort().join(','),'created,state,verifier');const saved=JSON.parse(e.stored),failed=env({hint:true,hash:'#auth=restart&state='+saved.state,saved:e.stored});await failed.context.OTPandaSession.ready;assert.equal(failed.context.localStorage.getItem('otpanda-session-present'),undefined);assert.equal(failed.context.location.assigned,undefined);const ok=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await ok.context.OTPandaSession.ready;assert.equal(ok.context.localStorage.getItem('otpanda-session-present'),'yes');assert.equal(JSON.stringify([...Object.values(ok.context.localStorage)]).includes(token),false);ok.context.OTPandaSession.logout();assert.equal(ok.context.localStorage.getItem('otpanda-session-present'),undefined);});
function flowEnv(key,value){return env({hash:'#'+key+'='+encodeURIComponent(JSON.stringify(value))+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});}
test('protection pending has no access and polling preserves bound state until approved, then fragment-only completion',async()=>{const p={token,pendingId:'match-request',expiresAt:NOW+600000},e=flowEnv('protection',p);await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'extra-verification');assert.equal(e.context.OTPandaSession.pendingLabel(),p.pendingId.slice(0,6).toUpperCase());assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.stored,undefined);let approved=false;e.context.fetch=async(url,o)=>{assert.equal(url,'https://otpanda-api.abrahammurciano.workers.dev/auth/google/protection/status');assert.equal(o.headers['X-OTPanda-Pending'],token);assert.equal(o.credentials,'omit');return {ok:true,text:async()=>JSON.stringify({status:approved?'approved':'waiting'})};};assert.equal(await e.context.OTPandaSession.protectionContinue('check'),'waiting');assert.equal(e.context.location.assigned,undefined);approved=true;await e.context.OTPandaSession.protectionContinue('check');assert.equal(e.context.location.assigned,'https://otpanda-api.abrahammurciano.workers.dev/auth/google/protection/complete#token='+token);assert.ok(!e.stored.includes(token));});
test('Google email continuation binds bearer header, typed short code and fragment-only completion',async()=>{const e=flowEnv('google',{email:'one@example.test',kind:'email',token,expiresAt:NOW+600000});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'google-email');assert.equal(e.context.OTPandaSession.email(),'one@example.test');assert.equal(e.context.OTPandaSession.access(),undefined);let calls=[];e.context.fetch=async(url,o)=>{calls.push({url,o});assert.equal(o.headers['X-OTPanda-Continuation'],token);assert.equal(o.credentials,'omit');return{ok:true,text:async()=>'{}'};};await e.context.OTPandaSession.googleContinue('email');await e.context.OTPandaSession.googleContinue('verify-email','ABCD2345');assert.equal(calls.length,2);assert.equal(JSON.parse(calls[1].o.body).emailProof,'ABCD2345');assert.ok(e.context.location.assigned.endsWith('/continue/complete#token='+token));assert.ok(!e.stored.includes(token));});
test('invalid or expired continuation/pending never enables new-flow methods',async()=>{for(const [key,value]of [['protection',{token,pendingId:'id',expiresAt:NOW}],['google',{token,kind:'email',email:'one@example.test',expiresAt:NOW+600001}],['google',{token,kind:'link',email:'one@example.test',expiresAt:NOW+600000,extra:true}]]){const e=flowEnv(key,value);await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'sign-in-required');assert.equal(e.calls,0);assert.equal(e.context.OTPandaSession.access(),undefined);}});
test('signup accepts a dashed short code, carries proof only in fragment and not storage',async()=>{const e=env();await e.context.OTPandaSession.ready;await e.context.OTPandaSession.signupEmail('one@example.test','ABCD-2345');const url=new URL(e.context.location.assigned);assert.equal(url.pathname,'/auth/signup/app');assert.equal(url.searchParams.has('email_token'),false);assert.equal(new URLSearchParams(url.hash.slice(1)).get('email_token'),'ABCD-2345');assert.equal(e.stored.includes('ABCD'),false);});
async function addKeyEnv(){const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;return e;}
function addOptions(){return{token,expiresAt:NOW+120000,options:{rp:{id:'otpanda.github.io',name:'OTPanda'},user:{id:'AQID',name:'a@example.test',displayName:''},challenge:'A'.repeat(43),authenticatorSelection:{userVerification:'required'},excludeCredentials:[{type:'public-key',id:'AQID'}]}};}
test('additional key requires assertion, memory grant and existing credential exclusion',async()=>{const e=await addKeyEnv(),steps=[];let created=0;e.context.navigator={credentials:{get:async()=>credential(),create:async o=>{created++;assert.equal(o.publicKey.excludeCredentials.length,1);assert.equal(o.publicKey.userVerification,undefined);assert.equal(o.publicKey.authenticatorSelection.userVerification,'required');const c=credential();c.response.attestationObject=new Uint8Array([1,2,3]).buffer;return c;}}};e.context.fetch=async(url,o)=>{const step=url.split('/').at(-1);steps.push(step);assert.equal(o.credentials,'omit');assert.equal(o.headers.Authorization,'Bearer '+token);if(step.startsWith('register-'))assert.equal(o.headers['X-OTPanda-Enrollment'],token);const v=step==='verify-begin'?{token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[{id:'AQID'}]}}:step==='verify-finish'?{token,expiresAt:NOW+120000}:step==='register-begin'?addOptions():{status:'registered'};return{ok:true,text:async()=>JSON.stringify(v)};};await e.context.OTPandaSession.addPasskey();assert.equal(created,1);assert.deepEqual(steps,['verify-begin','verify-finish','register-begin','register-finish']);assert.equal(e.stored,undefined);});
test('additional key logout during existing-key prompt cannot submit proof',async()=>{const e=await addKeyEnv();let release,calls=0;e.context.navigator={credentials:{get:()=>new Promise(r=>release=r)}};e.context.fetch=async()=>{calls++;return{ok:true,text:async()=>JSON.stringify({token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[{id:'AQID'}]}})};};const p=e.context.OTPandaSession.addPasskey();while(!release)await new Promise(r=>setImmediate(r));e.context.OTPandaSession.logout();release(credential());await assert.rejects(p);assert.equal(calls,1);});
test('logout failure marker is advisory only, clears restore hint and offers no access or auto restore',async()=>{const e=env({hash:'#auth=logout-incomplete&state=',hint:true});await e.context.OTPandaSession.ready;assert.equal(e.cleaned,true);assert.equal(e.context.OTPandaSession.status(),'logout-incomplete');assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.context.localStorage.getItem('otpanda-session-present'),undefined);assert.equal(e.context.location.assigned,undefined);assert.equal(e.calls,0);e.context.OTPandaSession.logout();assert.equal(e.context.location.assigned,'https://otpanda-api.abrahammurciano.workers.dev/auth/device/logout');});

test('valid callback automatically prompts once and completes without a second click',async()=>{let prompts=0;const c={token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),timeout:120000,userVerification:'required'}},e=env({hash:'#login='+Buffer.from(JSON.stringify(c)).toString('base64url')+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),navigator:{credentials:{get:async()=>{prompts++;return credential();}}},fetchImpl:async()=>({ok:true,text:async()=>JSON.stringify({handoff:token,expiresAt:NOW+60000})})});await e.context.OTPandaSession.ready;for(let i=0;i<12;i++)await Promise.resolve();assert.equal(prompts,1);assert.equal(e.context.OTPandaSession.status(),'completing');assert.ok(e.context.location.assigned.includes('/auth/login/complete#handoff='));});
test('browser gesture denial retains bounded callback for explicit retry without automatic loop',async()=>{let prompts=0;const c={token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),timeout:120000,userVerification:'required'}},e=env({hash:'#login='+Buffer.from(JSON.stringify(c)).toString('base64url')+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),navigator:{credentials:{get:async()=>{prompts++;throw new Error('NotAllowedError');}}}});await e.context.OTPandaSession.ready;for(let i=0;i<6;i++)await Promise.resolve();assert.equal(prompts,1);assert.equal(e.context.OTPandaSession.status(),'passkey-ready');assert.equal(e.stored,undefined);e.context.OTPandaSession.clear();await assert.rejects(e.context.OTPandaSession.passkey());assert.equal(prompts,1);});

test('server denial after an assertion never retries the consumed ceremony',async()=>{const e=loginEnv();await e.context.OTPandaSession.ready;e.context.navigator={credentials:{get:async()=>credential()}};e.context.fetch=async()=>({ok:false,text:async()=>'{}'});await e.context.OTPandaSession.passkey(true);assert.equal(e.context.OTPandaSession.status(),'sign-in-required');await assert.rejects(e.context.OTPandaSession.passkey());});
test('automatic OS prompt does not block bootstrap readiness or application mount',async()=>{let finish;const c={token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),timeout:120000,userVerification:'required'}},e=env({hash:'#login='+Buffer.from(JSON.stringify(c)).toString('base64url')+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),navigator:{credentials:{get:()=>new Promise(r=>finish=r)}}});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'authenticating');e.context.OTPandaSession.clear();finish(null);await Promise.resolve();assert.equal(e.context.OTPandaSession.status(),'idle');});

test('restoration remembers only bounded navigation enum and clears it on logout',async()=>{
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW,view:3})});
 await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.view(),3);
 for(const v of [-1,6,'3',{email:'private'},NaN])assert.throws(()=>e.context.OTPandaSession.setView(v));
 e.context.OTPandaSession.setView(5);assert.equal(e.context.sessionStorage.getItem('otpanda.view.tab.v1'),'5');assert.equal(e.stored,undefined);assert.equal(e.context.OTPandaSession.view(),5);
 await e.context.OTPandaSession.start('restore');const pending=JSON.parse(e.stored);assert.equal(pending.view,5);assert.deepEqual(Object.keys(pending).sort(),['created','state','verifier','view']);
 e.context.OTPandaSession.logout();assert.equal(e.context.OTPandaSession.view(),0);
});
test('bad callback navigation enum never grants access',async()=>{
 for(const view of [-1,6,'security',{query:'secret'}]){
  const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW,view})});
  await e.context.OTPandaSession.ready;assert.equal(e.calls,0);assert.equal(e.context.OTPandaSession.access(),undefined);
 }
});

async function renewingEnv(){
 const webcrypto=require('node:crypto').webcrypto;
 let publicKey,clock=NOW,accessIndex=0;
 const issued=['otpda_'+'b'.repeat(54)+'A','otpda_'+'c'.repeat(54)+'A'];
 const data=t=>({access:t,accessExpiresAt:clock+300000,renewal:{lineageId:'lineage_12345',handleId:t.slice(6,18),firstPartyExpiresAt:NOW+30*86400000,serverTime:clock}});
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),fetchImpl:async(url,o)=>{
   if(o.method==='GET')return{ok:true,status:200,text:async()=>'{}'};
   const body=JSON.parse(o.body);assert.equal(o.credentials,'omit');
   if(url.endsWith('/exchange')){publicKey=await webcrypto.subtle.importKey('raw',Buffer.from(body.renewal_key,'base64url'),{name:'ECDSA',namedCurve:'P-256'},false,['verify']);return{ok:true,text:async()=>JSON.stringify(data(issued[0]))};}
   assert.ok(url.endsWith('/renew'));assert.equal(o.headers.Authorization,'Bearer '+issued[accessIndex]);
   const msg=['otpanda-renew-v1','POST /auth/renew',body.lineage_id,issued[accessIndex].slice(6,18),String(body.expires_at)].join('\n');
   assert.equal(await webcrypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},publicKey,Buffer.from(body.signature,'base64url'),new TextEncoder().encode(msg)),true);
   accessIndex++;return{ok:true,text:async()=>JSON.stringify(data(issued[accessIndex]))};
 }});
 e.context.Date={now:()=>clock};await e.context.OTPandaSession.ready;
 return{...e,get stored(){return e.stored;},setClock:n=>clock=n,issued};
}
test('memory-only signing renewal is singleflight, no navigation and no persisted credential',async()=>{
 const e=await renewingEnv();e.setClock(NOW+250000);
 const reads=await Promise.all([e.context.OTPandaSession.read('/v1/manage/entries'),e.context.OTPandaSession.maintain()]);
 assert.equal(e.context.OTPandaSession.access(),e.issued[1]);assert.equal(e.context.location.assigned,undefined);
 assert.equal(e.stored,undefined);assert.equal(e.context.sessionStorage.getItem('otpanda.view.tab.v1'),null);
 assert.ok(!JSON.stringify(e.context).includes('privateKey'));
});
const refuseRenew=e=>{e.context.fetch=async(url)=>url.endsWith('/renew')?{ok:false,status:401,text:async()=>'{}'}:{status:200,text:async()=>'{}'};};
test('unattended tab does not heartbeat; expired access uses cookie restore on user request',async()=>{
 const e=await renewingEnv();e.setClock(NOW+250000);await e.context.OTPandaSession.maintain();assert.equal(e.context.OTPandaSession.access(),e.issued[0]);assert.equal(e.context.location.assigned,undefined);
 e.setClock(NOW+300000);await e.context.OTPandaSession.maintain();assert.equal(e.context.OTPandaSession.status(),'session-paused');assert.equal(e.context.location.assigned,undefined);
 refuseRenew(e);assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,503);assert.equal(e.context.location.assigned,undefined,'refused resume renewal drops the key first');assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,503);assert.ok(e.context.location.assigned.includes('/auth/restore?'));assert.equal(e.context.OTPandaSession.status(),'restoring');
});
test('lost renewal response keeps valid reads, never retries handle, restores only after expiry',async()=>{
 const e=await renewingEnv();e.setClock(NOW+250000);let calls=0;e.context.fetch=async(url)=>{if(url.endsWith('/renew')){calls++;throw Error('lost');}return{status:200,text:async()=>'{}'};};
 assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,200);assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,200);assert.equal(calls,1);assert.equal(e.context.location.assigned,undefined);
 e.setClock(NOW+300001);await e.context.OTPandaSession.read('/v1/manage/entries');assert.ok(e.context.location.assigned.includes('/auth/restore?'));
});
test('logout during signing cannot submit or resurrect renewal',async()=>{
 const e=await renewingEnv();e.setClock(NOW+250000);let release,calls=0;
 const native=e.context.crypto;e.context.crypto={...native,subtle:{sign:()=>new Promise(r=>release=r)}};
 e.context.fetch=async()=>{calls++;throw Error('must not call');};
 const task=e.context.OTPandaSession.read('/v1/manage/entries');while(!release)await new Promise(r=>setImmediate(r));e.context.OTPandaSession.logout();release(new Uint8Array(64).buffer);await task;assert.equal(calls,0);assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.context.OTPandaSession.status(),'idle');
});
test('server clock anchors access and cookie deadlines without changing lifetime',async()=>{
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),response:{access:token,accessExpiresAt:NOW+3600000+300000,renewal:{lineageId:'lineage_12345',handleId:token.slice(6,18),serverTime:NOW+3600000}}});
 await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'restored');assert.equal(e.context.OTPandaSession.access(),token);assert.equal(e.context.OTPandaSession.accessExpiresAt(),NOW+300000);
});
test('429 renewal cools down without redirect storm or spent-handle retry',async()=>{
 const e=await renewingEnv();e.setClock(NOW+250000);let calls=0;e.context.fetch=async(url)=>{if(url.endsWith('/renew')){calls++;return{ok:false,status:429};}return{status:200,text:async()=>'{}'};};
 await e.context.OTPandaSession.read('/v1/manage/entries');await e.context.OTPandaSession.read('/v1/manage/entries');assert.equal(calls,1);assert.equal(e.context.location.assigned,undefined);
 e.setClock(NOW+300000);await e.context.OTPandaSession.read('/v1/manage/entries');assert.equal(calls,1);assert.equal(e.context.location.assigned,undefined);
 e.setClock(NOW+310001);await e.context.OTPandaSession.read('/v1/manage/entries');assert.equal(calls,2,'resume renewal retried after cooldown');assert.equal(e.context.location.assigned,undefined,'429 never navigates');
});
test('missing cookie deadline cannot activate renewal or bypass first-party restore',async()=>{
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),response:{access:token,accessExpiresAt:NOW+300000,renewal:{lineageId:'lineage_12345',handleId:token.slice(6,18),serverTime:NOW}}});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaSession.status(),'restored');e.context.Date={now:()=>NOW+300001};await e.context.OTPandaSession.read('/v1/manage/entries');assert.ok(e.context.location.assigned.includes('/auth/restore?'));
});

test('visible focused view renews without clicks while hidden view sends no heartbeat',async()=>{
 const e=await renewingEnv();e.context.document={visibilityState:'visible',hasFocus:()=>true};e.setClock(NOW+250000);await e.context.OTPandaSession.maintain();assert.equal(e.context.OTPandaSession.access(),e.issued[1]);assert.equal(e.context.location.assigned,undefined);
});
test('malformed successor cannot mutate accepted server clock',async()=>{
 const e=await renewingEnv();e.setClock(NOW+250000);e.context.fetch=async(url)=>url.endsWith('/renew')?{ok:true,text:async()=>JSON.stringify({access:'invalid',accessExpiresAt:1,renewal:{serverTime:NOW+999999999999}})}:{status:200,text:async()=>'{}'};
 await e.context.OTPandaSession.read('/v1/manage/entries');assert.equal(e.context.OTPandaSession.accessExpiresAt(),NOW+300000);assert.equal(e.context.OTPandaSession.access(),e.issued[0]);
});
test('blocked restoration watchdog and bfcache return release stale restore promise',async()=>{
 const e=await renewingEnv();let watchdog;const listeners={};e.context.setTimeout=(f)=>{watchdog=f;};e.context.addEventListener=(name,f)=>{listeners[name]=f;};
 // Reload into a context with lifecycle listeners installed before bootstrap.
 const other=vm.createContext({...e.context,OTPandaSession:undefined,location:{...e.context.location,hash:''},localStorage:{getItem:()=>null,setItem(){},removeItem(){}},sessionStorage:{getItem:()=>null,setItem(){},removeItem(){}}});
 vm.runInContext(script,other);await other.OTPandaSession.ready;assert.equal(typeof listeners.pageshow,'function');listeners.pageshow({persisted:true});assert.equal(other.OTPandaSession.status(),'idle');
 e.setClock(NOW+300001);refuseRenew(e);await e.context.OTPandaSession.read('/v1/manage/entries');await e.context.OTPandaSession.read('/v1/manage/entries');assert.equal(e.context.OTPandaSession.status(),'restoring');assert.equal(typeof watchdog,'function');watchdog();assert.equal(e.context.OTPandaSession.status(),'session-paused');
});
test('429 preserves successful current reads during cooldown',async()=>{
 const e=await renewingEnv();e.setClock(NOW+250000);e.context.fetch=async(url)=>url.endsWith('/renew')?{ok:false,status:429}:{status:200,text:async()=>'{}'};
 assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,200);assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,200);
});
test('visible but unfocused window renews, hidden tab does not',async()=>{
 const e=await renewingEnv();e.context.document={visibilityState:'visible',hasFocus:()=>false};e.setClock(NOW+250000);await e.context.OTPandaSession.maintain();assert.equal(e.context.OTPandaSession.access(),e.issued[1]);
});
test('successful renewal commits new clock offset only after full validation',async()=>{
 const e=await renewingEnv();e.setClock(NOW+250000);e.context.fetch=async(url)=>url.endsWith('/renew')?{ok:true,text:async()=>JSON.stringify({access:e.issued[1],accessExpiresAt:NOW+950000,renewal:{lineageId:'lineage_12345',handleId:e.issued[1].slice(6,18),serverTime:NOW+650000,firstPartyExpiresAt:NOW+30*86400000}})}:{status:200,text:async()=>'{}'};
 assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,200);assert.equal(e.context.OTPandaSession.accessExpiresAt(),NOW+550000);
});
test('watchdog releases restore for later retry without replacing PKCE during backoff',async()=>{
 const e=await renewingEnv();e.setClock(NOW+300001);let timer;e.context.setTimeout=(fn)=>timer=fn;refuseRenew(e);
 await e.context.OTPandaSession.read('/v1/manage/entries');await e.context.OTPandaSession.read('/v1/manage/entries');const first=e.stored;timer();await e.context.OTPandaSession.read('/v1/manage/entries');assert.equal(e.stored,first);
 e.setClock(NOW+310002);await e.context.OTPandaSession.read('/v1/manage/entries');assert.notEqual(e.stored,first);
});
test('pageshow persisted releases actual restoring and renewing references',async()=>{
 const listeners={},webcrypto=require('node:crypto').webcrypto;let clock=NOW,release;
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});
 e.context.location.hash='#code='+token+'&state='+state;e.context.sessionStorage.getItem=k=>k==='otpanda.restore.tab.v1'?JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}):null;
 const next='otpda_'+'b'.repeat(54)+'A';e.context.fetch=async()=>({ok:true,text:async()=>JSON.stringify({access:next,accessExpiresAt:clock+300000,renewal:{lineageId:'lineage_12345',handleId:next.slice(6,18),serverTime:clock,firstPartyExpiresAt:NOW+30*86400000}})});
 const other=vm.createContext({...e.context,OTPandaSession:undefined,addEventListener:(n,f)=>listeners[n]=f,Date:{now:()=>clock}});vm.runInContext(script,other);await other.OTPandaSession.ready;
 clock=NOW+300001;await other.OTPandaSession.read('/v1/manage/entries');const first=other.location.assigned;listeners.pageshow({persisted:true});await other.OTPandaSession.read('/v1/manage/entries');assert.notEqual(other.location.assigned,first);
});
test('day-early cookie handoff honors watchdog cooldown and keeps PKCE stable',async()=>{
 let clock=NOW,timer;const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),response:{access:token,accessExpiresAt:NOW+300000,renewal:{lineageId:'lineage_12345',handleId:token.slice(6,18),serverTime:NOW,firstPartyExpiresAt:NOW+43200000}}});e.context.Date={now:()=>clock};await e.context.OTPandaSession.ready;e.context.setTimeout=f=>timer=f;clock=NOW+250000;await e.context.OTPandaSession.read('/v1/manage/entries');const before=e.stored;timer();await e.context.OTPandaSession.read('/v1/manage/entries');assert.equal(e.stored,before);assert.equal(e.context.OTPandaSession.status(),'restored');
});

test('401 cookie restore is singleflight and denied refresh clears hint without loop',async()=>{
 const e=await renewingEnv();e.context.fetch=async()=>({status:401,text:async()=>'{}'});await e.context.OTPandaSession.read('/v1/manage/entries');const nav=e.context.location.assigned;assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,503);assert.equal(e.context.location.assigned,nav);assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');
 const saved=JSON.parse(e.stored),failed=env({hint:true,hash:'#auth=sign-in&state='+saved.state,saved:e.stored});await failed.context.OTPandaSession.ready;assert.equal(failed.context.OTPandaSession.status(),'sign-in-required');assert.equal(failed.context.localStorage.getItem('otpanda-session-present'),undefined);assert.equal(failed.context.location.assigned,undefined);
});

test('read401 cooldown survives exchange and successful mixed-endpoint reads until logout or elapsed window',async()=>{
 const sessionValues=new Map(),saved=JSON.stringify({state,verifier:'v'.repeat(43),created:NOW});
 const first=env({hash:'#code='+token+'&state='+state,saved,sessionValues});await first.context.OTPandaSession.ready;first.context.fetch=async()=>({status:401,text:async()=>'{}'});await first.context.OTPandaSession.read('/v1/manage/session');assert.ok(first.context.location.assigned.includes('/auth/restore?'));
 const second=env({hash:'#code='+token+'&state='+state,saved,sessionValues});await second.context.OTPandaSession.ready;second.context.fetch=async()=>({status:401,text:async()=>'{}'});assert.equal((await second.context.OTPandaSession.read('/v1/manage/session')).status,503);assert.equal(second.context.location.assigned,undefined);assert.equal(second.context.OTPandaSession.access(),undefined);assert.equal(second.context.localStorage.getItem('otpanda-session-present'),'yes');
 const third=env({hash:'#code='+token+'&state='+state,saved,sessionValues});await third.context.OTPandaSession.ready;third.context.fetch=async()=>({status:200,text:async()=>'{}'});await third.context.OTPandaSession.read('/v1/manage/session');assert.equal(sessionValues.has('otpanda.read.restore.v1'),true);third.context.fetch=async()=>({status:401,text:async()=>'{}'});await third.context.OTPandaSession.read('/v1/manage/session');assert.equal(third.context.location.assigned,undefined);third.context.OTPandaSession.logout();assert.equal(sessionValues.has('otpanda.read.restore.v1'),false);
});

test('401 stalled restore watchdog exposes actionable sign-in instead of dead paused reads',async()=>{
 const e=await renewingEnv();let watchdog;e.context.setTimeout=f=>watchdog=f;e.context.fetch=async()=>({status:401,text:async()=>'{}'});await e.context.OTPandaSession.read('/v1/manage/session');const navigation=e.context.location.assigned;assert.equal(e.context.OTPandaSession.status(),'restoring');watchdog();assert.equal(e.context.OTPandaSession.status(),'sign-in-required');e.setClock(NOW+70000);await e.context.OTPandaSession.maintain();assert.equal(e.context.location.assigned,navigation);assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');
});

test('401 cooldown storage unavailable fails closed and explicit clear resets guard',async()=>{
 const e=await renewingEnv();e.context.sessionStorage.setItem=()=>{throw Error('storage unavailable');};e.context.fetch=async()=>({status:401,text:async()=>'{}'});await e.context.OTPandaSession.read('/v1/manage/session');assert.equal(e.context.location.assigned,undefined);assert.equal(e.context.OTPandaSession.status(),'sign-in-required');assert.equal(e.context.OTPandaSession.access(),undefined);
 const sessionValues=new Map([['otpanda.read.restore.v1',String(NOW)]]),fresh=env({sessionValues});fresh.context.OTPandaSession.clear();assert.equal(sessionValues.has('otpanda.read.restore.v1'),false);
});
test('read401 guard permits another bounded attempt after window without erasing cookie capability',async()=>{
 const sessionValues=new Map([['otpanda.read.restore.v1',String(NOW-60001)]]),e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),sessionValues});await e.context.OTPandaSession.ready;e.context.fetch=async()=>({status:401,text:async()=>'{}'});await e.context.OTPandaSession.read('/v1/manage/session');assert.ok(e.context.location.assigned.includes('/auth/restore?'));assert.equal(sessionValues.get('otpanda.read.restore.v1'),String(NOW));
});

test('page hash is not an auth callback and never consumes a pending ceremony',async()=>{
 const saved=JSON.stringify({state,verifier:'v'.repeat(43),created:NOW});
 const e=env({hash:'#/settings/devices',saved});await e.context.OTPandaSession.ready;
 assert.equal(e.cleaned,false);assert.equal(e.stored,saved);assert.equal(e.calls,0);
 assert.equal(e.context.OTPandaSession.status(),'idle');assert.equal(e.context.OTPandaNavigation.current(),'settings/devices');
});
test('page destination survives canonical login and only identifiers are stored',async()=>{
 const e=env({hash:'#/settings/organization'});await e.context.OTPandaSession.start('login');
 const record=JSON.parse(e.stored);assert.equal(record.route,'settings/organization');
 assert.equal(new URL(e.context.location.assigned).searchParams.get('redirect_uri'),'https://otpanda.github.io/app/');
 assert.ok(!e.context.location.assigned.includes('settings'));
});
test('successful callback restores intended route after proof has been removed',async()=>{
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW,route:'settings/devices'})});
 assert.ok(e.cleaned);await e.context.OTPandaSession.ready;
 assert.equal(e.context.OTPandaNavigation.current(),'settings/devices');assert.equal(e.context.OTPandaSession.status(),'restored');
});
test('unknown or parameter-bearing page links cannot become commands or destinations',async()=>{
 for(const hash of ['#/settings/devices?signout=all','#/https://evil.test','#/settings/recovery/complete','#/%2e%2e','#/settings/devices#code=secret']){
  const e=env({hash});await e.context.OTPandaSession.ready;assert.equal(e.context.OTPandaNavigation.current(),'codes');assert.equal(e.calls,0);assert.equal(e.context.OTPandaSession.status(),'idle');
 }
 const e=env();assert.throws(()=>e.context.OTPandaNavigation.go('https://evil.test'));
});
test('untrusted stored callback route is rejected before exchange',async()=>{
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW,route:'https://evil.test'})});await e.context.OTPandaSession.ready;assert.equal(e.calls,0);assert.equal(e.context.OTPandaSession.status(),'sign-in-required');
});
test('page navigation uses history entries and back listeners without action fetches',async()=>{
 const e=env({hash:'#/codes'});const writes=[];
 e.context.history.pushState=(_s,_t,url)=>{writes.push(url);e.context.location.hash=url.slice(url.indexOf('#'));};
 let changed=0;e.context.OTPandaNavigation.listen(()=>changed++);
 e.context.OTPandaNavigation.go('sources');e.context.OTPandaNavigation.go('entries');
 assert.deepEqual(writes,['/app/#/sources','/app/#/entries']);assert.equal(changed,2);assert.equal(e.calls,0);
});
test('recovery deep links open a view without restoring, sending mail or security effects',async()=>{
 for(const hash of ['#/recovery','#/recovery/start','#/recovery/finish']){
  const e=env({hash,hint:true});await e.context.OTPandaSession.ready;
  assert.equal(e.context.location.assigned,undefined);assert.equal(e.calls,0);assert.equal(e.context.OTPandaSession.status(),'idle');
 }
});
test('real history events select page and sanitize unknown destinations without fetching',async()=>{
 const e=env({hash:'#/codes'}),handlers={};
 e.context.addEventListener=(name,f)=>{handlers[name]=f;};
 e.context.history.pushState=(_s,_t,url)=>{e.context.location.hash=url.slice(url.indexOf('#'));};
 e.context.history.replaceState=(_s,_t,url)=>{e.context.location.hash=url.slice(url.indexOf('#'));};
 const c=vm.createContext({...e.context,OTPandaSession:undefined,OTPandaNavigation:undefined});vm.runInContext(script,c);await c.OTPandaSession.ready;
 c.location.hash='#/settings/devices';handlers.popstate();assert.equal(c.OTPandaNavigation.current(),'settings/devices');
 c.location.hash='#/settings/account-security';handlers.hashchange();assert.equal(c.OTPandaNavigation.current(),'settings/account-security');
 c.location.hash='#/settings/devices?revoke=true';handlers.hashchange();assert.equal(c.OTPandaNavigation.current(),'codes');assert.equal(c.location.hash,'#/codes');assert.equal(e.calls,0);
});
test('public route exit restores existing cookie hint and public routes are not persisted',async()=>{
 const values=new Map([['otpanda.route.tab.v1','recovery/finish']]);
 const cold=env({sessionValues:values});await cold.context.OTPandaSession.ready;assert.equal(cold.context.OTPandaNavigation.current(),'codes');
 const e=env({hash:'#/recovery',hint:true});e.context.history.pushState=()=>{};await e.context.OTPandaSession.ready;e.context.OTPandaNavigation.go('codes');for(let n=0;n<50&&!e.context.location.assigned;n++)await new Promise(r=>setTimeout(r,2));assert.ok(e.context.location.assigned.includes('/auth/restore?'));
});

test('hung management read and body abort and permit the next read automatically',async()=>{for(const bodyHung of [false,true]){const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;let timer,aborted;e.context.setTimeout=f=>(timer=f,1);e.context.clearTimeout=()=>{};e.context.fetch=async(u,o)=>{aborted=o.signal;return bodyHung?{status:200,body:{getReader:()=>({read:()=>new Promise(()=>{}),cancel(){},releaseLock(){}})}}:await new Promise(()=>{});};const pending=e.context.OTPandaSession.read('/v1/manage/entries');await new Promise(r=>setImmediate(r));timer();await assert.rejects(pending);assert.equal(aborted.aborted,true);e.context.fetch=async()=>({status:200,text:async()=>'{}'});assert.equal((await e.context.OTPandaSession.read('/v1/manage/entries')).status,200);}});

test('hung signed renewal is bounded and valid access remains usable',async()=>{const e=await renewingEnv();e.setClock(NOW+250000);let timer,signal;e.context.setTimeout=f=>(timer=f,1);e.context.clearTimeout=()=>{};e.context.fetch=async(u,o)=>{signal=o.signal;return await new Promise(()=>{});};const pending=e.context.OTPandaSession.read('/v1/manage/entries');await new Promise(r=>setTimeout(r,20));timer();await new Promise(r=>setTimeout(r,20));timer();await assert.rejects(pending);assert.equal(signal.aborted,true);assert.equal(e.context.OTPandaSession.status(),'restored');});

test('TOTP enrollment requires exact passkey proof, no cookies or persisted key',async()=>{
 const e=await addKeyEnv(),steps=[],key='GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';let prompts=0;
 e.context.navigator={credentials:{get:async o=>{prompts++;assert.equal(o.publicKey.userVerification,'required');return credential();}}};
 e.context.fetch=async(url,o)=>{steps.push(url);assert.equal(o.credentials,'omit');assert.equal(o.redirect,'error');assert.equal(o.cache,'no-store');assert.equal(o.headers.Authorization,'Bearer '+token);const b=JSON.parse(o.body);assert.equal(b.secret,key);assert.equal(b.label,'Example');assert.equal(b.account,'person');if(url.endsWith('/begin')){assert.deepEqual(Object.keys(b).sort(),['account','label','secret']);return {ok:true,text:async()=>JSON.stringify({token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[{id:'AQID'}]}})};}assert.deepEqual(Object.keys(b).sort(),['account','label','response','secret','token']);return{ok:true,text:async()=>' {"entryId":"new-entry"}'};};
 assert.equal(await e.context.OTPandaSession.addTotp('Example','person',key),'new-entry');assert.equal(prompts,1);assert.equal(steps.length,2);assert.equal(e.stored,undefined);assert.equal([...e.context.localStorage.getItem('otpanda-session-present')].join(''),'yes');
});
test('TOTP logout during OS prompt cannot submit seed mutation',async()=>{const e=await addKeyEnv();let release,calls=0;e.context.navigator={credentials:{get:()=>new Promise(r=>release=r)}};e.context.fetch=async()=>{calls++;return{ok:true,text:async()=>JSON.stringify({token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[]}})};};const p=e.context.OTPandaSession.addTotp('Example','','GEZDGNBVGY3TQOJQ');while(!release)await new Promise(r=>setImmediate(r));e.context.OTPandaSession.logout();release(credential());await assert.rejects(p);assert.equal(calls,1);});
test('TOTP rejects weak assertion options and foreign RP before platform prompt',async()=>{for(const patch of [{userVerification:'preferred'},{rpId:'evil.test'}]){const e=await addKeyEnv();let prompts=0;e.context.navigator={credentials:{get:async()=>{prompts++;return credential();}}};e.context.fetch=async()=>({ok:true,text:async()=>JSON.stringify({token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[],...patch}})});await assert.rejects(e.context.OTPandaSession.addTotp('Example','','GEZDGNBVGY3TQOJQ'));assert.equal(prompts,0);}});
test('TOTP code lookup is bounded no-store GET and late logout hides response',async()=>{const e=await addKeyEnv();let release;e.context.fetch=(url,o)=>{assert.equal(url,'https://otpanda-api.abrahammurciano.workers.dev/v1/manage/totp-code?entry=new-entry');assert.equal(o.method,'GET');assert.equal(o.credentials,'omit');assert.equal(o.cache,'no-store');return new Promise(r=>release=()=>r({status:200,text:async()=>'{"code":"123456"}'}));};const p=e.context.OTPandaSession.totpCode('new-entry');while(!release)await new Promise(r=>setImmediate(r));e.context.OTPandaSession.logout();release();assert.deepEqual(JSON.parse(JSON.stringify(await p)),{status:401,body:'{}'});});

// Resume after the access life: bearer-less signed request, no navigation.
test('lapsed tab with its key sends a bearer-less signed resume (new domain, head handle id) and never navigates; cookie under 24h no longer forces a redirect',async()=>{
 const e=await renewingEnv();e.context.document={visibilityState:'visible'};e.setClock(NOW+3600000);
 let seen;e.context.fetch=async(url,o)=>{seen={url,o};return{ok:true,text:async()=>JSON.stringify({access:e.issued[1],accessExpiresAt:NOW+3600000+300000,renewal:{lineageId:'lineage_12345',handleId:e.issued[1].slice(6,18),serverTime:NOW+3600000,firstPartyExpiresAt:NOW+30*86400000}})};};
 assert.equal(await e.context.OTPandaSession.maintain(),true);
 assert.ok(seen.url.endsWith('/auth/renew'));assert.equal(seen.o.headers.Authorization,undefined);assert.equal(seen.o.credentials,'omit');
 const b=JSON.parse(seen.o.body);assert.deepEqual(Object.keys(b).sort(),['expires_at','handle_id','lineage_id','signature']);assert.equal(b.handle_id,e.issued[0].slice(6,18));
 assert.equal(e.context.location.assigned,undefined);assert.equal(e.context.OTPandaSession.access(),e.issued[1]);
});
test('hidden lapsed tab sends nothing until shown; a 429 or an offline error on resume never navigates and keeps the key',async()=>{
 const e=await renewingEnv();e.context.document={visibilityState:'hidden'};e.setClock(NOW+3600000);let calls=0;e.context.fetch=async()=>{calls++;throw new TypeError('offline');};
 assert.equal(await e.context.OTPandaSession.maintain(),false);assert.equal(calls,0);
 e.context.document.visibilityState='visible';await e.context.OTPandaSession.maintain();assert.equal(calls,1);assert.equal(e.context.location.assigned,undefined);
 e.setClock(NOW+3600000+10001);e.context.fetch=async()=>({ok:false,status:429,text:async()=>'{}'});await e.context.OTPandaSession.maintain();assert.equal(e.context.location.assigned,undefined);
});
test('cookie deadline already passed: lapsed tab with its key still resumes in place, never navigates solely for the cookie',async()=>{
 const e=await renewingEnv();e.context.document={visibilityState:'visible'};const T=NOW+31*86400000;e.setClock(T);let calls=0;
 e.context.fetch=async()=>{calls++;return{ok:true,text:async()=>JSON.stringify({access:e.issued[1],accessExpiresAt:T+300000,renewal:{lineageId:'lineage_12345',handleId:e.issued[1].slice(6,18),serverTime:T,firstPartyExpiresAt:NOW+30*86400000}})};};
 assert.equal(await e.context.OTPandaSession.maintain(),true);assert.equal(calls,1);assert.equal(e.context.location.assigned,undefined);assert.equal(e.context.OTPandaSession.access(),e.issued[1]);
});

test('Gmail status unavailable is honest and never starts OAuth',async()=>{const e=await addKeyEnv();let calls=0;e.context.fetch=async(url,o)=>{calls++;assert.ok(url.endsWith('/v1/manage/gmail-source/status'));assert.equal(o.credentials,'omit');assert.equal(o.cache,'no-store');return{status:503,text:async()=>'{}'};};const r=await e.context.OTPandaSession.gmailSourceStatus();assert.equal(r.status,200);assert.equal(JSON.parse(r.body).ready,false);assert.equal(calls,1);assert.equal(e.context.location.assigned,undefined);});
const GS='https://www.googleapis.com/auth/';const gmailAuthUrl=(o={})=> 'https://accounts.google.com/o/oauth2/v2/auth?'+new URLSearchParams({client_id:'367143149550-cu61adcdqclntipnl84e096kp35vduvk.apps.googleusercontent.com',redirect_uri:'https://otpanda-api.abrahammurciano.workers.dev/sources/gmail/oauth/callback',response_type:'code',scope:[GS+'gmail.readonly',GS+'gmail.labels',GS+'gmail.settings.basic'].join(' '),access_type:'offline',prompt:'consent',include_granted_scopes:'false',state:'a'.repeat(64),code_challenge:'A'.repeat(43),code_challenge_method:'S256',...o});
test('Gmail source needs passkey then validates separate label-mode OAuth destination',async()=>{const e=await addKeyEnv();let prompts=0,posts=0;e.context.navigator={credentials:{get:async()=>{prompts++;return credential();}}};e.context.fetch=async(url,o)=>{posts++;assert.equal(o.credentials,'omit');assert.equal(o.headers.Authorization,'Bearer '+token);const v=JSON.parse(o.body);assert.equal(v.action,'connect');assert.equal(v.sourceId,'');return{ok:true,text:async()=>JSON.stringify(url.endsWith('/begin')?{token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[]}}:{ok:true,authorizationUrl:gmailAuthUrl()})};};await e.context.OTPandaSession.connectGmail();assert.equal(prompts,1);assert.equal(posts,2);assert.equal(new URL(e.context.location.assigned).origin,'https://accounts.google.com');assert.equal(e.stored,undefined);});
test('Gmail source rejects unapproved OAuth scopes or endpoint',async()=>{for(const replacement of ['https://evil.test/','https://accounts.google.com/o/oauth2/v2/auth?scope=mail.google.com']){const e=await addKeyEnv();e.context.navigator={credentials:{get:async()=>credential()}};e.context.fetch=async url=>({ok:true,text:async()=>JSON.stringify(url.endsWith('/begin')?{token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[]}}:{ok:true,authorizationUrl:replacement})});await assert.rejects(e.context.OTPandaSession.connectGmail());assert.equal(e.context.location.assigned,undefined);}});
test('Gmail logout during passkey prompt cannot submit connect or navigate',async()=>{const e=await addKeyEnv();let release,posts=0;e.context.navigator={credentials:{get:()=>new Promise(r=>release=r)}};e.context.fetch=async()=>{posts++;return{ok:true,text:async()=>JSON.stringify({token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[]}})};};const p=e.context.OTPandaSession.connectGmail();while(!release)await new Promise(r=>setImmediate(r));e.context.OTPandaSession.clear();release(credential());await assert.rejects(p);assert.equal(posts,1);assert.equal(e.context.location.assigned,undefined);});

test('Gmail OAuth must request exactly the three disclosed scopes at the current callback',async()=>{for(const o of [{scope:GS+'gmail.readonly'},{scope:GS+'gmail.readonly '+GS+'gmail.labels'},{scope:[GS+'gmail.readonly',GS+'gmail.labels',GS+'gmail.settings.basic',GS+'gmail.modify'].join(' ')},{scope:[GS+'gmail.readonly',GS+'gmail.readonly',GS+'gmail.labels'].join(' ')},{redirect_uri:'https://otpanda-api.abrahammurciano.workers.dev/sources/gmail/callback'}]){const e=await addKeyEnv();e.context.navigator={credentials:{get:async()=>credential()}};e.context.fetch=async url=>({ok:true,text:async()=>JSON.stringify(url.endsWith('/begin')?{token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[]}}:{ok:true,authorizationUrl:gmailAuthUrl(o)})});await assert.rejects(e.context.OTPandaSession.connectGmail());assert.equal(e.context.location.assigned,undefined);}});
test('Gmail OAuth scope order does not matter',async()=>{const e=await addKeyEnv();e.context.navigator={credentials:{get:async()=>credential()}};e.context.fetch=async url=>({ok:true,text:async()=>JSON.stringify(url.endsWith('/begin')?{token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[]}}:{ok:true,authorizationUrl:gmailAuthUrl({scope:[GS+'gmail.settings.basic',GS+'gmail.readonly',GS+'gmail.labels'].join(' ')})})});await e.context.OTPandaSession.connectGmail();assert.ok(e.context.location.assigned);});
function disconnectEnv(finalBody,finalOk=true){return addKeyEnv().then(e=>{e.context.navigator={credentials:{get:async()=>credential()}};e.context.fetch=async url=>({ok:url.endsWith('/begin')||finalOk,text:async()=>JSON.stringify(url.endsWith('/begin')?{token,expiresAt:NOW+120000,options:{rpId:'otpanda.github.io',userVerification:'required',challenge:'A'.repeat(43),allowCredentials:[]}}:finalBody)});return e;});}
test('Gmail disconnect returns only sanitized booleans from the API result',async()=>{const e=await disconnectEnv({disconnected:true,remoteRevoked:false,googlePermissionRemains:true,artifactsRemoved:true,leaked:'x'});const r=JSON.parse(await e.context.OTPandaSession.disconnectGmail('source_1'));assert.deepEqual(r,{disconnected:true,googlePermissionRemains:true,lifecycleBlocked:false,artifactsRemoved:true});});
test('Gmail disconnect reports unresolved lifecycle without claiming artifact removal',async()=>{const e=await disconnectEnv({disconnected:true,remoteRevoked:false,googlePermissionRemains:true,lifecycleBlocked:true});const r=JSON.parse(await e.context.OTPandaSession.disconnectGmail('source_1'));assert.deepEqual(r,{disconnected:true,googlePermissionRemains:true,lifecycleBlocked:true});});
test('Gmail disconnect blocked by an in-flight operation changes nothing and is reported, not thrown',async()=>{const e=await disconnectEnv({disconnected:false,lifecycleBlocked:true});const r=JSON.parse(await e.context.OTPandaSession.disconnectGmail('source_1'));assert.equal(r.disconnected,false);assert.equal(r.lifecycleBlocked,true);});
test('Gmail disconnect plain failure still throws',async()=>{const e=await disconnectEnv({disconnected:false});await assert.rejects(e.context.OTPandaSession.disconnectGmail('source_1'));});

// Signed-in "Connect Google": same tab, marker holds only state and route.
const LINK_KEY='otpanda.google-link.tab.v1',ticketValue='t'.repeat(43),pendingLink=(extra={})=>({email:'a@example.test',kind:'link-only',token,expiresAt:NOW+600000,...extra});
const linkHash=(g,st=state)=>'#google='+encodeURIComponent(JSON.stringify(g))+'&state='+st;
const marker=(patch={})=>JSON.stringify({state,route:'settings/account-security',created:NOW,...patch});
function linkEnv(hash,m=marker()){const sessionValues=new Map(m?[[LINK_KEY,m]]:[]);const e=env({hint:true,hash,sessionValues});return {e,sessionValues};}
const restoreNotice=e=>JSON.parse(e.stored).linkNotice;
test('connectGoogle asks for a ticket with the memory bearer, stores only state and route, keeps session and hint',async()=>{
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;
 assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');
 let call;e.context.fetch=async(url,o)=>{call={url,o};return{ok:true,status:200,text:async()=>JSON.stringify({ticket:ticketValue,expiresAt:NOW+60000})};};
 const sv=new Map();e.context.sessionStorage.setItem=(k,v)=>sv.set(k,v);
 assert.equal(await e.context.OTPandaSession.connectGoogle(),'');
 assert.match(call.url,/\/v1\/manage\/google\/link\/ticket$/);assert.equal(call.o.method,'POST');assert.equal(call.o.headers.Authorization,'Bearer '+token);assert.equal(call.o.credentials,'omit');
 const sent=JSON.parse(call.o.body);assert.deepEqual(Object.keys(sent),['state']);assert.match(sent.state,/^[A-Za-z0-9_-]{43}$/);
 const m=JSON.parse(sv.get(LINK_KEY));assert.equal(m.state,sent.state);assert.deepEqual(Object.keys(m).sort(),['created','route','state']);assert.ok(!sv.get(LINK_KEY).includes(token));
 assert.match(e.context.location.assigned,/\/auth\/google\/link\/start\?ticket=t{43}$/);
 assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');assert.equal(e.context.OTPandaSession.access(),token);
});
test('connectGoogle refusals return a reason and never navigate or store a marker',async()=>{
 for(const [status,body,reason] of [[409,{error:'no_passkey'},'no_passkey'],[409,{error:'already_linked'},'already_linked'],[429,{error:'retry'},'retry'],[401,{},'signin'],[500,{},'unavailable']]){
  const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW})});await e.context.OTPandaSession.ready;
  e.context.fetch=async()=>({ok:false,status,text:async()=>JSON.stringify(body)});const sv=new Map();e.context.sessionStorage.setItem=(k,v)=>sv.set(k,v);
  assert.equal(await e.context.OTPandaSession.connectGoogle(),reason);assert.equal(e.context.location.assigned,undefined);assert.equal(sv.size,0);assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');
 }
});
test('link-only return with matching marker shows verify, keeps hint, no access, marker consumed',async()=>{
 const {e,sessionValues}=linkEnv(linkHash(pendingLink()));assert.ok(e.cleaned);await e.context.OTPandaSession.ready;
 assert.equal(e.context.OTPandaSession.status(),'google-link-only');assert.equal(e.context.OTPandaSession.email(),'a@example.test');assert.equal(e.context.OTPandaSession.access(),undefined);
 assert.equal(sessionValues.has(LINK_KEY),false);assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');assert.equal(e.context.location.assigned,undefined);assert.equal(e.calls,0);
});
test('link-only passkey verify uses continuation header only, then restores with a connected notice and never calls complete',async()=>{
 const {e}=linkEnv(linkHash(pendingLink()));await e.context.OTPandaSession.ready;const calls=[];
 e.context.navigator={credentials:{get:async()=>credential()}};
 e.context.fetch=async(url,o)=>{calls.push({url,o});assert.equal(o.headers['X-OTPanda-Continuation'],token);assert.equal(o.headers.Authorization,undefined);assert.equal(o.credentials,'omit');return{ok:true,status:200,text:async()=>JSON.stringify(url.endsWith('/begin')?{token,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),userVerification:'required',timeout:120000,allowCredentials:[]}}:{status:'ok'})};};
 await e.context.OTPandaSession.googleContinue('link-only');
 assert.deepEqual(calls.map(c=>c.url.split('/').pop()),['begin','verify']);const v=JSON.parse(calls[1].o.body);assert.deepEqual(Object.keys(v).sort(),['ceremony','emailProof','response']);assert.equal(v.emailProof,'');
 assert.match(e.context.location.assigned,/\/auth\/restore\?/);assert.ok(!e.context.location.assigned.includes('/continue/complete'));
 assert.equal(restoreNotice(e),'connected');assert.equal(JSON.parse(e.stored).route,'settings/account-security');assert.ok(!e.stored.includes(token));
 assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');
});
test('dismissed passkey prompt keeps the pending link; cancel restores with a cancelled notice',async()=>{
 const {e}=linkEnv(linkHash(pendingLink()));await e.context.OTPandaSession.ready;
 e.context.navigator={credentials:{get:async()=>{throw Error('NotAllowed');}}};
 e.context.fetch=async()=>({ok:true,status:200,text:async()=>JSON.stringify({token,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),userVerification:'required',timeout:120000,allowCredentials:[]}})});
 await assert.rejects(()=>e.context.OTPandaSession.googleContinue('link-only'));assert.equal(e.context.location.assigned,undefined);assert.equal(e.context.OTPandaSession.status(),'google-link-only');
 await e.context.OTPandaSession.googleContinue('link-cancel');assert.match(e.context.location.assigned,/\/auth\/restore\?/);assert.equal(restoreNotice(e),'cancelled');
});
test('refused begin or verify restores with a restart notice, session hint kept',async()=>{
 for(const failAt of ['begin','verify']){
  const {e}=linkEnv(linkHash(pendingLink()));await e.context.OTPandaSession.ready;
  e.context.navigator={credentials:{get:async()=>credential()}};
  e.context.fetch=async url=>url.endsWith('/'+failAt)?{ok:false,status:403,text:async()=>'{"error":"restart"}'}:{ok:true,status:200,text:async()=>JSON.stringify({token,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),userVerification:'required',timeout:120000,allowCredentials:[]}})};
  await e.context.OTPandaSession.googleContinue('link-only');assert.match(e.context.location.assigned,/\/auth\/restore\?/);assert.equal(restoreNotice(e),'restart');assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');
 }
});
test('an ordinary Google continuation with a live link marker stays ordinary and keeps the marker',async()=>{
 const sessionValues=new Map([[LINK_KEY,marker({state:'m'.repeat(43)})]]);const g={email:'a@example.test',kind:'link',token,expiresAt:NOW+600000};
 const e=env({hash:linkHash(g),saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW}),sessionValues});await e.context.OTPandaSession.ready;
 assert.equal(e.context.OTPandaSession.status(),'google-link');assert.equal(sessionValues.has(LINK_KEY),true);
});
test('restore carrying a link notice exposes it exactly once; bad notices are refused',async()=>{
 const e=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW,route:'settings/account-security',linkNotice:'connected'})});await e.context.OTPandaSession.ready;
 assert.equal(e.context.OTPandaSession.status(),'restored');assert.equal(e.context.OTPandaSession.googleLinkResult(),'connected');assert.equal(e.context.OTPandaSession.googleLinkResult(),'');
 const bad=env({hash:'#code='+token+'&state='+state,saved:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW,linkNotice:'<b>'})});await bad.context.OTPandaSession.ready;
 assert.equal(bad.context.OTPandaSession.status(),'sign-in-required');assert.equal(bad.context.OTPandaSession.googleLinkResult(),'');
});
const restores=e=>/\/auth\/restore\?/.test(e.context.location.assigned??'');
const OLD=NOW-600001,ANCIENT=NOW-90000000;
test('link-only success needs the exact state and a marker under 10 minutes; without a matching marker it is an unknown hash',async()=>{
 for(const [hash,m] of [[linkHash(pendingLink()),null],[linkHash(pendingLink(),'x'.repeat(43)),marker()],[linkHash(pendingLink(),'x'.repeat(43)),marker({created:OLD})]]){
  const {e}=linkEnv(hash,m);await e.context.OTPandaSession.ready;assert.notEqual(e.context.OTPandaSession.status(),'google-link-only');assert.equal(e.context.OTPandaSession.access(),undefined);assert.equal(e.context.location.assigned,undefined);assert.equal(e.context.OTPandaSession.status(),'sign-in-required');assert.equal(e.context.localStorage.getItem('otpanda-session-present'),undefined);
 }
});
test('a matching-state link return that is malformed ends the attempt: restore only, hint kept, never the sign-in parser',async()=>{
 for(const hash of [linkHash(pendingLink({extra:1})),linkHash(pendingLink({kind:'link'})),linkHash(pendingLink({kind:'email'})),linkHash(pendingLink({token:'bad'})),linkHash(pendingLink({expiresAt:NOW-1})),linkHash(pendingLink({expiresAt:NOW+700000})),linkHash(pendingLink({email:5})),'#google=%7Bnot-json&state='+state,'#link=bogus&state='+state]){
  const {e,sessionValues}=linkEnv(hash);await e.context.OTPandaSession.ready;
  assert.notEqual(e.context.OTPandaSession.status(),'google-link-only');assert.ok(restores(e),hash);assert.equal(restoreNotice(e),'restart');assert.equal(sessionValues.has(LINK_KEY),false);assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');assert.equal(e.context.OTPandaSession.access(),undefined);assert.ok(!e.stored.includes(token));
 }
});
test('a matching but older-than-10-minutes link-only return restores only, never offers or accepts the token',async()=>{
 for(const created of [OLD,ANCIENT]){
  const {e,sessionValues}=linkEnv(linkHash(pendingLink()),marker({created}));await e.context.OTPandaSession.ready;
  assert.notEqual(e.context.OTPandaSession.status(),'google-link-only');assert.ok(restores(e));assert.equal(restoreNotice(e),'restart');assert.equal(sessionValues.has(LINK_KEY),false);assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');assert.ok(!e.stored.includes(token));
 }
});
test('link restart or mismatch ends the attempt at any marker age: restore, notice, hint kept; wrong state with a live marker restores only; no marker is ordinary',async()=>{
 for(const created of [NOW,OLD,ANCIENT])for(const [reason,st] of [['restart',state],['restart',''],['mismatch',state],['restart','x'.repeat(43)],['mismatch','y'.repeat(43)],['bogus','x'.repeat(43)]]){
  const {e,sessionValues}=linkEnv('#link='+reason+'&state='+st,marker({created}));await e.context.OTPandaSession.ready;
  assert.ok(restores(e));assert.equal(restoreNotice(e),['restart','mismatch'].includes(reason)?reason:'restart');assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');assert.equal(sessionValues.has(LINK_KEY),false);
 }
 for(const [m,st] of [[null,state],[null,'x'.repeat(43)]]){
  const {e}=linkEnv('#link=restart&state='+st,m);await e.context.OTPandaSession.ready;assert.equal(e.context.location.assigned,undefined);assert.equal(e.context.OTPandaSession.status(),'sign-in-required');
 }
});
test('ordinary failure hash with a link marker and no saved ordinary record only restores; with a saved record or no marker it stays ordinary',async()=>{
 for(const created of [NOW,OLD,ANCIENT])for(const hash of ['#auth=restart&state=','#auth=retry&state=','#auth=restart&state='+state]){
  const {e,sessionValues}=linkEnv(hash,marker({created}));await e.context.OTPandaSession.ready;
  assert.ok(restores(e));assert.equal(restoreNotice(e),'restart');assert.equal(e.context.localStorage.getItem('otpanda-session-present'),'yes');assert.equal(sessionValues.has(LINK_KEY),false);
 }
 const savedRecord=JSON.stringify({state,verifier:'v'.repeat(43),created:NOW});
 const withKey=env({hint:true,hash:'#auth=restart&state='+state,saved:savedRecord,sessionValues:new Map([[LINK_KEY,marker()]])});await withKey.context.OTPandaSession.ready;
 assert.equal(withKey.context.localStorage.getItem('otpanda-session-present'),undefined);assert.equal(withKey.context.location.assigned,undefined);
 const noMarker=linkEnv('#auth=restart&state=',null);await noMarker.e.context.OTPandaSession.ready;assert.equal(noMarker.e.context.localStorage.getItem('otpanda-session-present'),undefined);assert.equal(noMarker.e.context.location.assigned,undefined);
 for(const hash of ['#auth=sign-in&state=','#auth=restart&state=&x=1','#auth=email-sent&state=']){
  const {e}=linkEnv(hash);await e.context.OTPandaSession.ready;assert.equal(e.context.location.assigned,undefined);
 }
});
