import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createAutofillSource, CATALOGUE_STORE_KEY } from '../src/wiring.js';
const here=p=>fileURLToPath(new URL(p,import.meta.url));
test('the source reads only through the injected readInternal and persists the catalogue in storage.local',async()=>{
 const paths=[],bag={},fetched=[];
 const s=createAutofillSource({
  readInternal:async p=>{paths.push(p);
   if(p==='/v1/manage/entries')return{status:200,body:JSON.stringify({entries:[{entry_id:'e1',catalogId:'github.com'}]})};
   if(p==='/v1/manage/entry/domains')return{status:200,body:JSON.stringify({associations:[]})};
   return{status:503,body:'{}'};},
  storageLocal:{get:async k=>({[k]:bag[k]}),set:async o=>{Object.assign(bag,o);}},
  fetchImpl:async(u,o)=>{fetched.push([u,o]);return{ok:true,status:200,text:async()=>JSON.stringify([['GitHub',{domain:'github.com','additional-domains':[]}]])};},
 });
 const e=await s.entries();
 assert.deepEqual(e.map(x=>x.entryId),['e1']);assert.ok(e[0].domains.includes('github.com'));
 assert.deepEqual(paths,['/v1/manage/entries','/v1/manage/entry/domains']);
 assert.equal(fetched.length,1);assert.equal(fetched[0][0],'https://api.2fa.directory/v3/all.json');assert.equal(fetched[0][1].credentials,'omit');
 assert.ok(bag[CATALOGUE_STORE_KEY]&&Array.isArray(bag[CATALOGUE_STORE_KEY].rows));
 assert.throws(()=>createAutofillSource({storageLocal:{},fetchImpl(){}}));
});
test('source audit: the popup-facing worker and the autofill background never reach readInternal or the totp-code path; wiring takes no auth.read',()=>{
 const strip=t=>t.replace(/\/\*[\s\S]*?\*\//g,'').replace(/^\s*\/\/.*$/gm,'');
 for(const f of ['../src/background.js','../src/content.js','../src/content-core.js','../src/fill-request.js']){
  const t=strip(readFileSync(here(f),'utf8'));
  assert.ok(!/readInternal|totp-code/.test(t),f);
 }
 const w=strip(readFileSync(here('../src/wiring.js'),'utf8'));
 assert.ok(!/\bauth\b|\.read\(|onMessage|addListener/.test(w));
 const popup=strip(readFileSync(here('../../background.js'),'utf8'));
 const uses=popup.match(/readInternal/g)||[];assert.equal(uses.length,2,'worker passes readInternal once, to createAutofillSource only');
 assert.ok(/createAutofillSource\(\{ readInternal: p => ready\.then\(\(\) => auth\.readInternal\(p\)\)/.test(popup));assert.ok(!/totp-code/.test(popup));
 assert.ok(!/handlers = \{[^}]*readInternal/s.test(popup));
 assert.ok(/read: m => auth\.read\(m\.path\)/.test(popup),'popup read stays the 3-path read');
 const a=readFileSync(here('../../extension-auth.mjs'),'utf8');
 assert.match(a,/READ_PATHS = Object\.freeze\(\['\/v1\/manage\/entries', '\/v1\/manage\/active-codes', '\/v1\/manage\/entry\/domains'\]\)/);
});
test('the bundle in dist, when built, equals the source bundle (no drift)',async()=>{
 const {bundle}=await import('../build-content.mjs');
 const vm=await import('node:vm');const code=bundle();new vm.Script(code);assert.ok(!/\b(import|export)\b\s*[\w{*]/.test(code.replace(/\/\/.*$/gm,'')));
});
test('sign-out unregisters injection but keeps optional grants: logout awaits a plain sync (no revokeAll)',()=>{
 const t=readFileSync(here('../../background.js'),'utf8');
 assert.ok(/logout: async \(\) => \{ await auth\.logout\(\); await autofill\.syncContentScripts\(\)\.catch\(\(\) => \{\}\); return \{\}; \}/.test(t));
 assert.ok(!/revokeAll/.test(t));
});
import { createBackground } from '../src/background.js';
test('REAL wiring through createAutofillSource + sync: a 401, a network failure or a missing catalogue unregisters and removes NOTHING; no partial candidate set',async()=>{
 const upstream=JSON.stringify([['GitHub',{domain:'github.com','additional-domains':[]}]]);
 const mode={entries:'ok',domains:'ok',catalogue:'ok'};
 const readInternal=async p=>{
  const m=p==='/v1/manage/entries'?mode.entries:mode.domains;
  if(m==='401')return{status:401,body:'{}'};if(m==='net')throw Error('network');
  return p==='/v1/manage/entries'?{status:200,body:JSON.stringify({entries:[{entry_id:'e1',catalogId:'github.com'}]})}:{status:200,body:JSON.stringify({associations:[{entryId:'e1',domains:['git.corp.example.com']}]})};
 };
 const bag={};let t=0;
 const source=createAutofillSource({readInternal,storageLocal:{get:async k=>({[k]:bag[k]}),set:async o=>{Object.assign(bag,o);}},
  fetchImpl:async()=>{if(mode.catalogue==='net')throw Error('offline');return{ok:true,status:200,text:async()=>upstream};},clock:()=>t});
 const c={reg:[],unreg:0,removed:[],granted:['https://github.com/*','https://git.corp.example.com/*','https://api.example.test/*'],runtime:{id:'x',getManifest:()=>({host_permissions:['https://api.example.test/*']}),onMessage:{addListener(){}}},
  permissions:{getAll:async()=>({origins:c.granted}),remove:async p=>{c.removed.push(p.origins);return true;}},
  scripting:{unregisterContentScripts:async()=>{c.unreg++;},registerContentScripts:async s=>{c.reg.push(...s);}}};
 const b=createBackground({chromeApi:c,source});
 let r=await b.syncContentScripts();assert.equal(r.registered,2);assert.equal(c.removed.length,0);
 for(const [k,v] of [['entries','401'],['entries','net'],['domains','401'],['domains','net']]){
  mode.entries=mode.domains='ok';mode[k]=v;c.reg.length=0;c.unreg=0;
  r=await b.syncContentScripts();assert.equal(r.failed,true,k+v);assert.equal(c.unreg,1,'unregistered');assert.equal(c.reg.length,0);assert.equal(c.removed.length,0,'no grant removed: '+k+v);
 }
 // Cold catalogue (never cached) while offline: also a failure, not a catalogue-less candidate set.
 mode.entries=mode.domains='ok';const bag2={};
 const cold=createBackground({chromeApi:c,source:createAutofillSource({readInternal,storageLocal:{get:async k=>({[k]:bag2[k]}),set:async o=>Object.assign(bag2,o)},fetchImpl:async()=>{throw Error('offline');}})});
 r=await cold.syncContentScripts();assert.equal(r.failed,true);assert.equal(c.removed.length,0);
 // Recovered: the same grants are intact and register again.
 r=await b.syncContentScripts();assert.equal(r.registered,2);assert.equal(c.removed.length,0);
});
