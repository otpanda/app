import test from 'node:test';
import assert from 'node:assert/strict';
import { createBackground, SCRIPT_ID } from '../src/background.js';
const NOW=1_800_000_000_000;
function chromeFake({granted=true}={}){const c={removed:[],grantedOrigins:granted?['https://github.com/*']:[],listener:null,reg:[],unreg:0,asked:[],runtime:{id:'ext',getManifest:()=>({host_permissions:['https://api.example.test/*']}),onMessage:{addListener(f){c.listener=f;}}},
 permissions:{getAll:async()=>({origins:c.grantedOrigins}),remove:async p=>{c.removed.push(p.origins);c.grantedOrigins=c.grantedOrigins.filter(o=>!p.origins.includes(o));return true;}},scripting:{unregisterContentScripts:async()=>{c.unreg++;},registerContentScripts:async s=>{c.reg.push(...s);}}};return c;}
const ask=(c,sender,msg={type:'otpanda-fill-request'})=>new Promise(res=>{const keep=c.listener(msg,sender,res);if(keep===false)return;});
const source=()=>({entries:async()=>[{entryId:'gh',domains:['github.com']}],code:async id=>({entryId:id,code:'123456',receivedAt:NOW-1,expiresAt:NOW+9999})});
const sender={id:'ext',tab:{id:1,active:true},url:'https://github.com/x',frameId:0};
test('without a source it is inert: no registration and no code',async()=>{
 const c=chromeFake();const b=createBackground({chromeApi:c});assert.deepEqual(await ask(c,sender),{status:'none'});assert.equal((await b.syncContentScripts()).registered,0);assert.equal(c.reg.length,0);
});
test('a fill request is answered from the browser-provided sender, async response kept open',async()=>{
 const c=chromeFake();createBackground({chromeApi:c,source:source(),clock:()=>NOW});
 let kept;const p=new Promise(res=>{kept=c.listener({type:'otpanda-fill-request'},sender,res);});assert.equal(kept,true);assert.equal((await p).status,'ok');
 assert.equal((await ask(c,{...sender,url:'https://github.com.evil.example/'})).status,'none');
 assert.equal((await ask(c,{...sender,id:'someone-else'})).status,'none');
});
test('content script registered only on exact-host patterns and only when the optional permission is already granted; never broad',async()=>{
 const c=chromeFake({granted:true});const b=createBackground({chromeApi:c,source:source(),clock:()=>NOW});
 assert.equal((await b.syncContentScripts()).registered,1);
 assert.equal(c.reg[0].id,SCRIPT_ID);assert.deepEqual(c.reg[0].matches,['https://github.com/*']);assert.equal(c.reg[0].matchOriginAsFallback,false);
 const d=chromeFake({granted:false});const bd=createBackground({chromeApi:d,source:source()});assert.equal((await bd.syncContentScripts()).registered,0);assert.equal(d.reg.length,0);assert.equal(d.unreg,1,'stale registration removed');
 const e=chromeFake();const be=createBackground({chromeApi:e,source:{entries:async()=>[{entryId:'x',domains:['*.com','http://a.com']}],code:async()=>undefined}});assert.equal((await be.syncContentScripts()).registered,0);assert.equal(e.reg.length,0);
});
test('popup messages are not answered by the fill listener; grant/revoke/startup events re-sync registration',async()=>{
 const c=chromeFake({granted:true});const ev={};const mk=n=>({addListener:f=>{ev[n]=f;}});c.permissions.onAdded=mk('added');c.permissions.onRemoved=mk('removed');c.runtime.onStartup=mk('startup');c.runtime.onInstalled=mk('inst');
 createBackground({chromeApi:c,source:source(),clock:()=>NOW});
 assert.equal(c.listener({type:'status'},{id:'ext',url:'chrome-extension://ext/index.html'},()=>assert.fail('answered')),false);
 for(const n of ['added','removed','startup','inst']){c.reg.length=0;ev[n]();await new Promise(r=>setTimeout(r,5));assert.equal(c.reg.length,1,n);assert.deepEqual(c.reg[0].matches,['https://github.com/*']);assert.deepEqual(c.reg[0].js,['autofill/content.js']);}
 c.grantedOrigins=[];c.reg.length=0;ev.removed();await new Promise(r=>setTimeout(r,5));assert.equal(c.reg.length,0,'revoked: unregistered, nothing registered');
});

test('partial grants register only the granted candidates; stale granted hosts are revoked (never the API host); failed read fails closed; revokeAll on sign-out',async()=>{
 const c=chromeFake();c.grantedOrigins=['https://github.com/*','https://old.example/*','https://api.example.test/*','http://insecure.example/*'];
 let ents=[{entryId:'a',domains:['github.com']},{entryId:'b',domains:['new.example']}];
 const b=createBackground({chromeApi:c,source:{entries:async()=>{if(ents==='fail')throw Error('x');return ents;},code:async()=>undefined}});
 let r=await b.syncContentScripts();
 assert.deepEqual(c.reg[0].matches,['https://github.com/*'],'new.example is a candidate but not granted: not injected');assert.deepEqual(r.patterns.sort(),['https://github.com/*','https://new.example/*']);
 assert.equal(JSON.stringify(c.removed[0]),JSON.stringify(['https://old.example/*']),'only the https, non-required, non-candidate grant is removed');
 c.removed.length=0;c.reg.length=0;ents='fail';r=await b.syncContentScripts();assert.equal(r.failed,true);assert.equal(c.reg.length,0);assert.equal(c.removed.length,0,'a failed read revokes nothing');
 ents=[];c.grantedOrigins=['https://github.com/*'];c.unreg=0;r=await b.syncContentScripts({revokeAll:true});assert.equal(c.removed[0][0],'https://github.com/*');assert.equal(c.reg.length,0);
});
test('overlapping syncs are serialized and coalesced; the last request (logout revokeAll after sign-in) decides the final state',async()=>{
 const c=chromeFake();c.grantedOrigins=['https://github.com/*'];let gate,inCrit=0,maxCrit=0,reads=0;
 const slow=()=>new Promise(r=>{gate=r;});const origGetAll=c.permissions.getAll;
 c.permissions.getAll=async()=>{inCrit++;maxCrit=Math.max(maxCrit,inCrit);await new Promise(r=>setTimeout(r,5));const v=await origGetAll();inCrit--;return v;};
 const order=[];const reg=c.scripting.registerContentScripts,un=c.scripting.unregisterContentScripts;c.scripting.registerContentScripts=async s=>{order.push('reg');return reg(s);};
 const b=createBackground({chromeApi:c,source:{entries:async()=>{reads++;await new Promise(r=>setTimeout(r,5));return[{entryId:'a',domains:['github.com']}];},code:async()=>undefined}});
 const p1=b.syncContentScripts();await new Promise(r=>setTimeout(r,1));/* p1 is now running (in its critical section) */
 const p2=b.syncContentScripts();const p3=b.syncContentScripts({revokeAll:true});const p4=b.syncContentScripts({revokeAll:true});
 assert.notEqual(p1,p2);assert.equal(p2,p3);assert.equal(p3,p4,'callers arriving during a run share ONE queued follow-up');
 const r=await Promise.all([p1,p2,p3,p4]);
 assert.equal(maxCrit,1,'getAll never overlaps another sync');assert.equal(order.length,1,'the first run registered, the follow-up (latest options) did not');
 assert.equal(reads,1,'revokeAll follow-up reads no candidates; one run + one coalesced follow-up in total');
 assert.equal(JSON.stringify(c.removed.at(-1)),JSON.stringify(['https://github.com/*']),'final run revoked everything');assert.equal(c.grantedOrigins.length,0);
 assert.equal(r[0].registered,1);assert.equal(r[3].registered,0);
 const b2=createBackground({chromeApi:chromeFake({granted:true}),source:source(),clock:()=>NOW});assert.equal((await b2.syncContentScripts()).registered,1,'a sync after the burst runs normally');
});
test('after sign-out (candidate read fails) the script is unregistered and every granted origin is kept',async()=>{
 const c=chromeFake();c.grantedOrigins=['https://github.com/*'];let signedIn=true;
 const b=createBackground({chromeApi:c,source:{entries:async()=>{if(!signedIn)throw Error('401');return[{entryId:'a',domains:['github.com']}];},code:async()=>undefined}});
 assert.equal((await b.syncContentScripts()).registered,1);signedIn=false;c.unreg=0;
 const r=await b.syncContentScripts();assert.equal(r.failed,true);assert.equal(c.unreg,1);assert.equal(c.removed.length,0);assert.equal(c.grantedOrigins.length,1);
});
