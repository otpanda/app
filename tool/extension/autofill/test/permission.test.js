import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const code=readFileSync(fileURLToPath(new URL('../src/permission.js',import.meta.url)),'utf8');
function load({active=true,origins=['https://github.com/*'],grant=true,workerOk=true,reqThrows=false,granted=['https://github.com/*','https://api.example.test/*']}={}){
 const calls=[];const clock={t:1_000_000};
 const ctx={navigator:{userActivation:{isActive:active}},Date:{now:()=>clock.t},JSON,Array,Set,Promise,String,Error,Object,
  chrome:{runtime:{getManifest:()=>({host_permissions:['https://api.example.test/*']}),sendMessage:async m=>{calls.push(['msg',m.type]);return workerOk?{ok:true,value:{origins}}:{ok:false};}},
  permissions:{contains:async p=>{calls.push(['contains',p.origins]);return false;},getAll:async()=>({origins:granted}),remove:async p=>{calls.push(['remove',p.origins]);return true;},
   request:async p=>{calls.push(['request',p.origins]);if(reqThrows)throw Error('x');return grant;}}}};
 ctx.globalThis=ctx;vm.createContext(ctx);vm.runInContext(code,ctx);return{api:ctx.OTPandaAutofill,calls,clock};
}
const J=JSON.stringify;
test('classic script: nothing happens at load, the API is frozen and read-only',()=>{
 const {api,calls}=load();assert.equal(calls.length,0);assert.ok(Object.isFrozen(api));assert.equal(Object.keys(api).sort().join(),'copy,prepare,request,revoke,status');assert.ok(!/^\s*(import|export)\s/m.test(code));
});
test('request needs a gesture and a fresh prepared list; it prompts only for validated exact https origins',async()=>{
 const n=load({active:false});await n.api.prepare();assert.equal(await n.api.request(),'needs-gesture');assert.ok(!n.calls.some(c=>c[0]==='request'));
 const g=load({origins:['https://github.com/*','http://evil.example/*','https://*.example.com/*','https://a.b.example/*','javascript:1','https://github.com/*']});
 assert.equal(await g.api.request(),'refresh','nothing prepared yet: no prompt, no guess');assert.ok(!g.calls.some(c=>c[0]==='request'));
 assert.equal(J(await g.api.prepare()),J({status:'ready',total:2,requested:2,truncated:false}));assert.equal(await g.api.request(),'granted');assert.equal(J(g.calls.find(c=>c[0]==='request')[1]),J(['https://a.b.example/*','https://github.com/*']));
 g.clock.t+=61_000;assert.equal(await g.api.request(),'refresh','stale list');
 const z=load({origins:[]});assert.equal((await z.api.prepare()).status,'none');assert.equal(await z.api.request(),'none');
});
test('decline and browser error are distinct; a worker failure is an error, not an empty list',async()=>{
 const d=load({grant:false});await d.api.prepare();assert.equal(await d.api.request(),'declined');
 const e=load({reqThrows:true});await e.api.prepare();assert.equal(await e.api.request(),'error');
 const w=load({workerOk:false});assert.equal((await w.api.prepare()).status,'error');assert.equal(await w.api.request(),'refresh');assert.equal((await w.api.status()).granted,false);
});
test('more than 500 candidates are reported, never silently cut: total/requested/truncated',async()=>{
 const many=Array.from({length:620},(_,i)=>`https://h${String(i).padStart(4,'0')}.example/*`);const m=load({origins:many});
 assert.equal(J(await m.api.prepare()),J({status:'ready',total:620,requested:500,truncated:true}));assert.equal(await m.api.request(),'granted');assert.equal(m.calls.find(c=>c[0]==='request')[1].length,500);
});
test('the grant request is made synchronously inside the tap: no await between request() and chrome.permissions.request',async()=>{
 const t=load();await t.api.prepare();t.calls.length=0;const p=t.api.request();
 assert.equal(J(t.calls.map(c=>c[0])),J(['request']));assert.equal(await p,'granted');
});
test('status never prompts; revoke removes granted optional https origins and never the required API host',async()=>{
 const s=load();const st=await s.api.status();assert.equal(st.granted,true);assert.equal(st.grantedCount,1);assert.equal(st.total,1);assert.ok(!s.calls.some(c=>c[0]==='request'));
 const r=load({granted:['https://github.com/*','https://old.example/*','https://api.example.test/*','http://x.example/*']});
 assert.equal(await r.api.revoke(),'removed');assert.equal(J(r.calls.find(c=>c[0]==='remove')[1]),J(['https://github.com/*','https://old.example/*']));
 assert.equal(await load({granted:['https://api.example.test/*']}).api.revoke(),'none');
 const part=load({origins:['https://github.com/*','https://b.example/*']});const ps=await part.api.status();assert.equal(ps.granted,false);assert.equal(ps.grantedCount,1);assert.equal(ps.total,2);
 const bad=await load({workerOk:false}).api.status();assert.equal(bad.error,true);assert.equal(bad.granted,false);
});
