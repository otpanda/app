const {test}=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');
const boot=fs.readFileSync('tool/session-bootstrap.js','utf8'),client=fs.readFileSync('tool/realtime-client.js','utf8');
const NOW=1800000000000,token='otpda_'+'a'.repeat(55),state='s'.repeat(43),TICKET='rt1.'+'A'.repeat(16)+'.'+'B'.repeat(43);
function streaming(r){if(r&&typeof r.text==='function'&&!r.body){r.body={getReader(){let sent=false;return{async read(){if(sent)return{done:true};sent=true;return{done:false,value:new TextEncoder().encode(await r.text())};},async cancel(){},releaseLock(){}};}};}return r;}
async function env({withClient=true,withWS=true,noSession=false}={}){
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
  if(withWS)context.WebSocket=WS;
  vm.createContext(context);if(withClient)vm.runInContext(client,context);vm.runInContext(boot,context);await context.OTPandaSession.ready;
  return {context,sockets,fetches,ctl};
}
const flush=async()=>{for(let i=0;i<30;i++)await new Promise(r=>setImmediate(r));};
test('without client script or WebSocket the bridge is inert',async()=>{for(const o of [{withClient:false},{withWS:false}]){const e=await env(o);assert.equal(e.context.OTPandaSession.realtimeState(),'unsupported');const un=e.context.OTPandaSession.realtimeSubscribe(()=>{});await flush();assert.equal(e.sockets.length,0);un();}});
test('subscribe mints one ticket with the memory bearer and opens one socket; hints reach listeners; unsubscribe stops',async()=>{const e=await env();assert.equal(e.context.OTPandaSession.status(),'restored');const got=[];const un=e.context.OTPandaSession.realtimeSubscribe(r=>got.push(r));await flush();const t=e.fetches.filter(f=>f.url.endsWith('/auth/realtime/ticket'));assert.equal(t.length,1);assert.equal(t[0].o.headers.Authorization,'Bearer '+token);assert.equal(t[0].o.credentials,'omit');assert.equal(e.sockets.length,1);assert.equal(JSON.stringify(e.sockets[0].protocols),JSON.stringify(['otpanda.v1',TICKET]));e.sockets[0].onopen();await flush();e.sockets[0].onmessage({data:'{"v":1,"t":"changed"}'});await flush();assert.equal(got[0],'connect');assert.equal(e.context.OTPandaSession.realtimeState(),'open');const un2=e.context.OTPandaSession.realtimeSubscribe(()=>{});assert.equal(e.sockets.length,1,'second subscriber shares the socket');un2();assert.equal(e.context.OTPandaSession.realtimeState(),'open');un();assert.equal(e.context.OTPandaSession.realtimeState(),'stopped');assert.equal(JSON.stringify(e.sockets[0].closed),'[1000]');});
test('clear/logout closes the socket and a late open or hint reaches nobody',async()=>{const e=await env();const got=[];const un=e.context.OTPandaSession.realtimeSubscribe(r=>got.push(r));await flush();const s=e.sockets[0];e.context.OTPandaSession.clear();assert.equal(e.context.OTPandaSession.realtimeState(),'waiting');assert.equal(JSON.stringify(s.closed),'[1000]');assert.equal(s.onopen,null);assert.equal(got.length,0);assert.equal(e.context.OTPandaSession.realtimeState(),'waiting','listeners kept: waits for a later restore, not a permanent stop');un();assert.equal(e.context.OTPandaSession.realtimeState(),'stopped');});
test('listener must be a function; a throwing listener does not break others',async()=>{const e=await env();assert.throws(()=>e.context.OTPandaSession.realtimeSubscribe(1));const got=[];e.context.OTPandaSession.realtimeSubscribe(()=>{throw Error('x');});e.context.OTPandaSession.realtimeSubscribe(r=>got.push(r));await flush();e.sockets[0].onopen();await flush();assert.equal(JSON.stringify(got),'["connect"]');e.context.OTPandaSession.clear();});
test('ticket is absent from the exposed session surface and storage',async()=>{const e=await env();e.context.OTPandaSession.realtimeSubscribe(()=>{});await flush();e.sockets[0].onopen();await flush();assert.ok(!JSON.stringify(Object.keys(e.context.OTPandaSession)).includes('ticket'));assert.ok(!(e.context.sessionStorage.getItem('otpanda.restore.tab.v1')||'').includes('rt1'));assert.ok(!(e.context.localStorage.getItem('otpanda-session-present')||'').includes('rt1'));e.context.OTPandaSession.clear();});

test('subscribe before restore (no session yet) waits locally with no ticket request; no permanent stop',async()=>{const e=await env({noSession:true});assert.equal(e.context.OTPandaSession.status(),'idle');const un=e.context.OTPandaSession.realtimeSubscribe(()=>{});await flush();assert.equal(e.fetches.filter(f=>f.url.endsWith('/auth/realtime/ticket')).length,0);assert.equal(e.sockets.length,0);assert.equal(e.context.OTPandaSession.realtimeState(),'waiting');un();assert.equal(e.context.OTPandaSession.realtimeState(),'stopped');});

test('state-only events: connection-lost replays to new listeners and clears on recovery with connect catch-up; neither state event is a data hint',async()=>{
 const e=await env();e.ctl.fast=true;e.ctl.statuses=[404];const S=e.context.OTPandaSession,a=[],conn=[];assert.equal(S.realtimeConnection().status,'ok');
 const offConn=S.realtimeConnectionSubscribe(c=>conn.push(c.status+':'+c.reason));const un=S.realtimeSubscribe(r=>a.push(r));await flush();
 assert.deepEqual(a,['connection-lost']);assert.deepEqual(conn,['lost:unavailable']);assert.equal(S.realtimeConnection().retrying,true);
 const b=[];const un2=S.realtimeSubscribe(r=>b.push(r));assert.deepEqual(b,['connection-lost'],'replayed to a new listener');un2();
 for(let i=0;i<100&&e.sockets.length===0;i++)await new Promise(r=>setTimeout(r,2));assert.ok(e.sockets.length>=1,'slow retry reached the second ticket (200)');e.sockets.at(-1).onopen();await flush();
 assert.deepEqual(a,['connection-lost','connection-restored','connect'],'restored, then the catch-up data hint');assert.equal(S.realtimeConnection().status,'ok');
 const c=[];const un3=S.realtimeSubscribe(r=>c.push(r));assert.deepEqual(c,[],'no stale lost replay after recovery');un3();un();offConn();});
test('a transient 503 ticket failure emits no state event before the 120s threshold',async()=>{
 const e=await env();const S=e.context.OTPandaSession,got=[];e.ctl.ticketStatus=503;const un=S.realtimeSubscribe(r=>got.push(r));await flush();
 assert.equal(S.realtimeState(),'backoff');assert.deepEqual(got,[]);un();});

test('snapshot bridge propagates numeric and HTTP-date Retry-After',async()=>{
 const e=await env();e.ctl.retryAfter='90';let r=await e.context.OTPandaSession.read('/v1/manage/session');assert.equal(r.retryAfterSeconds,90);
 e.ctl.retryAfter=new Date(NOW+120000).toUTCString();r=await e.context.OTPandaSession.read('/v1/manage/session');assert.equal(r.retryAfterSeconds,120);
 e.ctl.retryAfter='invalid';r=await e.context.OTPandaSession.read('/v1/manage/session');assert.equal(r.retryAfterSeconds,null);
});
