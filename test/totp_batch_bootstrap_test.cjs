const {test}=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');
const boot=fs.readFileSync('tool/session-bootstrap.js','utf8'),client=fs.readFileSync('tool/realtime-client.js','utf8');
const NOW=1800000000000,token='otpda_'+'a'.repeat(55),state='s'.repeat(43),TICKET='rt1.'+'A'.repeat(16)+'.'+'B'.repeat(43);
function streaming(r){if(r&&typeof r.text==='function'&&!r.body){r.body={getReader(){let sent=false;return{async read(){if(sent)return{done:true};sent=true;return{done:false,value:new TextEncoder().encode(await r.text())};},async cancel(){},releaseLock(){}};}};}return r;}
async function env({withClient=true,withWS=true,noSession=false,doc}={}){
  const ctl={ticketStatus:200,statuses:[],fast:false};
  const sockets=[],fetches=[];let stored=noSession?undefined:JSON.stringify({state,verifier:'v'.repeat(43),created:NOW});const hints=new Map(),sess=new Map();
  class WS{constructor(u,p){this.url=u;this.protocols=p;this.protocol='otpanda.v1';this.closed=[];sockets.push(this);}close(c){this.closed.push(c);}}
  const location={origin:'https://otpanda.github.io',pathname:'/app/',search:'',hash:noSession?'':'#code='+token+'&state='+state,assign(u){location.assigned=u;}};
  const context={AbortController,setTimeout:(f,ms)=>{const h=setTimeout(f,ctl.fast&&ms>=30000?1:ms);h.unref?.();return h;},clearTimeout,localStorage:{getItem:k=>hints.get(k),setItem:(k,v)=>hints.set(k,v),removeItem:k=>hints.delete(k)},location,history:{replaceState(){location.hash='';}},
   sessionStorage:{getItem(k){return k==='otpanda.restore.tab.v1'?stored:sess.get(k)??null;},removeItem(k){if(k==='otpanda.restore.tab.v1')stored=undefined;else sess.delete(k);},setItem(k,v){if(k==='otpanda.restore.tab.v1')stored=v;else sess.set(k,v);}},
   fetch:async(url,o)=>{fetches.push({url,o});if(url.endsWith('/auth/exchange'))return streaming({status:200,ok:true,text:async()=>JSON.stringify({access:token,accessExpiresAt:NOW+300000})});
     if(url.endsWith('/auth/realtime/ticket'))return streaming({status:ctl.statuses.length?ctl.statuses.shift():ctl.ticketStatus,headers:{get:()=>null},text:async()=>JSON.stringify({ticket:TICKET,expiresAt:NOW+30000,closeAt:NOW+300000,serverTime:NOW})});
     return streaming({status:200,ok:true,headers:{get:k=>k==='Retry-After'?ctl.retryAfter??null:null},text:async()=>'{"ownerId":"o","expiresAt":1}'});},
   URL,URLSearchParams,TextEncoder,TextDecoder,Uint8Array,atob:s=>Buffer.from(s,'base64').toString('binary'),btoa:s=>Buffer.from(s,'binary').toString('base64'),crypto:require('node:crypto').webcrypto,Date:class extends Date{static now(){return NOW;}}};
  if(doc)context.document=doc;
  if(withWS)context.WebSocket=WS;
  vm.createContext(context);if(withClient)vm.runInContext(client,context);vm.runInContext(boot,context);await context.OTPandaSession.ready;
  return {context,sockets,fetches,ctl};
}
const flush=async()=>{for(let i=0;i<30;i++)await new Promise(r=>setImmediate(r));};
const codesUrl='https://otpanda-api.abrahammurciano.workers.dev/v1/manage/totp-codes';
test('totpCodes validates 1 to 5 distinct entries before any request and sends one bearer GET with credentials omitted',async()=>{
  const e=await env({withClient:false});const S=e.context.OTPandaSession;
  for(const bad of [[],['a','b','c','d','e','f'],['a','a'],[''],[1],'a',['x'.repeat(257)],null])await assert.rejects(S.totpCodes(bad),/Entries required/);
  assert.equal(e.fetches.filter(f=>f.url.startsWith(codesUrl)).length,0);
  const r=await S.totpCodes(['a','b','c','d','e']);
  const f=e.fetches.filter(f=>f.url.startsWith(codesUrl));assert.equal(f.length,1);
  assert.equal(f[0].o.method,'GET');assert.equal(f[0].o.credentials,'omit');assert.equal(f[0].o.cache,'no-store');assert.equal(f[0].o.redirect,'error');
  assert.equal(f[0].o.headers.Authorization.startsWith('Bearer '),true);
  assert.deepEqual(new URL(f[0].url).searchParams.getAll('entry'),['a','b','c','d','e']);
  assert.equal(typeof r.status,'number');
});
test('totpCodes without a session makes no request and answers 401',async()=>{
  const e=await env({withClient:false,noSession:true});const r=await e.context.OTPandaSession.totpCodes(['a']);
  assert.equal(r.status,401);assert.equal(e.fetches.filter(f=>f.url.startsWith(codesUrl)).length,0);
});
test('page visibility reflects document.visibilityState and notifies listeners; a throwing listener is isolated',async()=>{
  let vis='visible';const ls=[];
  const doc={get visibilityState(){return vis;},addEventListener:(k,f)=>{if(k==='visibilitychange')ls.push(f);}};
  const e=await env({withClient:false,doc});const S=e.context.OTPandaSession;
  assert.equal(ls.length,1);assert.equal(S.pageHidden(),false);
  const seen=[];S.onPageVisibility(()=>{throw new Error('x');});const off=S.onPageVisibility(h=>seen.push(h));S.onPageVisibility('nope')();
  vis='hidden';ls[0]();assert.equal(S.pageHidden(),true);
  vis='visible';ls[0]();assert.equal(S.pageHidden(),false);
  assert.deepEqual(seen,[true,false]);
  off();off();vis='hidden';ls[0]();assert.deepEqual(seen,[true,false]);
});
test('page visibility without a document is visible and inert',async()=>{
  const e=await env({withClient:false});const S=e.context.OTPandaSession;
  assert.equal(S.pageHidden(),false);S.onPageVisibility(()=>{});
});
