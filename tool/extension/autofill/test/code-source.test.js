import test from 'node:test';
import assert from 'node:assert/strict';
import {createCodeSource,createCatalogueCache,parseUpstream,CATALOGUE_URL,CATALOGUE_LIMITS} from '../src/code-source.js';
import {createBackground} from '../src/background.js';
import {handleFillRequest} from '../src/fill-request.js';
const upstream=JSON.stringify([['GitHub',{domain:'github.com'}],['Amazon',{domain:'amazon.com','additional-domains':['amazon.de','AMAZON.fr','bad_host.com',5]}],['Bad',{domain:'*.x.com'}],['NoMap','x'],[5,{}]]);
const resp=(text,status=200)=>({ok:status===200,status,text:async()=>text});
const memStore=()=>{let v;return {get:async()=>v,set:async x=>{v=structuredClone(x);},peek:()=>v};};
test('upstream parse keeps valid lowercase hosts only, bounds size, rejects empty or non-arrays',()=>{
 assert.deepEqual(parseUpstream(upstream),[{n:'GitHub',d:['github.com']},{n:'Amazon',d:['amazon.com','amazon.de']}]);
 for(const bad of ['{}','[]','not json',JSON.stringify([['x','y']]),'['+'1,'.repeat(10)+'1]',' '.repeat(CATALOGUE_LIMITS.bytes+1)])assert.throws(()=>parseUpstream(bad));
});
test('catalogue cache: fetch once, then TTL; last good kept on failure; retries bounded; only the public URL, rows only stored',async()=>{
 let t=1000,calls=[],fail=false;const store=memStore();
 const c=createCatalogueCache({fetchText:async u=>{calls.push(u);if(fail)throw Error('net');return resp(upstream);},store,clock:()=>t});
 assert.equal((await c.rows()).length,2);assert.equal((await c.rows()).length,2);assert.deepEqual(calls,[CATALOGUE_URL]);
 assert.deepEqual(Object.keys(store.peek()).sort(),['at','rows']);
 fail=true;t+=CATALOGUE_LIMITS.ttlMs+1;assert.equal((await c.rows()).length,2,'stale last good served');assert.equal(calls.length,2);
 t+=1000;await c.rows();assert.equal(calls.length,2,'no retry inside 10 minutes');
 t+=CATALOGUE_LIMITS.retryMs;fail=false;await c.rows();assert.equal(calls.length,3);
 const warm=createCatalogueCache({fetchText:async()=>{throw Error('offline');},store,clock:()=>t});assert.equal((await warm.rows()).length,2,'cold worker restart reads the stored copy');
});
test('catalogue cache: no stored copy and a failing fetch gives undefined; bad status and oversize are failures; concurrent calls share one fetch',async()=>{
 const c=createCatalogueCache({fetchText:async()=>resp('x',500),store:memStore()});assert.equal(await c.rows(),undefined);
 const big=createCatalogueCache({fetchText:async()=>resp(' '.repeat(CATALOGUE_LIMITS.bytes+1)),store:memStore()});assert.equal(await big.rows(),undefined);
 let n=0;const one=createCatalogueCache({fetchText:async()=>{n++;await new Promise(r=>setTimeout(r,5));return resp(upstream);},store:memStore()});
 await Promise.all([one.rows(),one.rows(),one.rows()]);assert.equal(n,1);
 const bad=createCatalogueCache({fetchText:async()=>resp(upstream),store:{get:async()=>({at:'x',rows:[1]}),set:async()=>{throw Error('quota');}}});assert.equal((await bad.rows()).length,2);
});
const ok=o=>({status:200,body:JSON.stringify(o)});
function source(routes,rows=parseUpstream(upstream),opts={}){
 const reads=[];
 const read=async p=>{reads.push(p);const r=routes[p];if(typeof r==='function')return r();if(!r)return{status:503,body:'{}'};return r;};
 return {reads,source:createCodeSource({read,catalogue:{rows:async()=>rows},...opts})};
}
const entries=ok({entries:[{entry_id:'gh',service_name:'GitHub',catalogId:'github.com'},{entry_id:'mine',service_name:'github.com',catalogId:'Bad Id',service_id:'github.com'},{entry_id:'amz',catalogId:'amazon.com'},{entry_id:'bad id',catalogId:'github.com'}]});
test('entries(): catalogue domains by exact catalogId, plus the viewer\'s own; label and legacy service_id give nothing',async()=>{
 const {source:s,reads}=source({'/v1/manage/entries':entries,'/v1/manage/entry/domains':ok({associations:[{entryId:'mine',domains:['sso.corp.example.com']},{entryId:'gh',domains:['git.corp.example.com']}]})});
 assert.deepEqual(await s.entries(),[{entryId:'gh',domains:['git.corp.example.com','github.com']},{entryId:'mine',domains:['sso.corp.example.com']},{entryId:'amz',domains:['amazon.com','amazon.de']}]);
 assert.deepEqual(reads,['/v1/manage/entries','/v1/manage/entry/domains']);
});
test('entries() REJECTS when the association read or the catalogue is unavailable: never a partial candidate set (the worker revokes non-candidates)',async()=>{
 let fail=false;
 const {source:s}=source({'/v1/manage/entries':entries,'/v1/manage/entry/domains':()=>fail?{status:503,body:'{}'}:ok({associations:[{entryId:'gh',domains:['git.corp.example.com']}]})});
 assert.deepEqual((await s.entries()).find(e=>e.entryId==='gh').domains,['git.corp.example.com','github.com']);
 fail=true;await assert.rejects(s.entries(),/associations/);fail=false;assert.equal((await s.entries()).length>0,true,'recovers on the next call, nothing remembered');
 const none=createCodeSource({read:async p=>p.endsWith('entries')?entries:ok({associations:[{entryId:'gh',domains:['git.corp.example.com']}]}),catalogue:{rows:async()=>{throw Error('x');}}});
 await assert.rejects(none.entries(),/catalogue/);
 const bad=createCodeSource({read:async p=>p.endsWith('entries')?entries:ok({associations:'x'}),catalogue:{rows:async()=>[]}});await assert.rejects(bad.entries(),/associations/);
});
test('entries() rejects an unusable entries read; code() returns the newest active record for exactly that entry and never caches',async()=>{
 for(const r of [{status:401,body:'{}'},{status:200,body:'x'},ok({entries:'x'}),ok({entries:Array.from({length:5001},(_,i)=>({entry_id:'e'+i}))})])await assert.rejects(source({'/v1/manage/entries':r}).source.entries());
 let recs=[{entryId:'gh',code:'111111',receivedAt:10,expiresAt:100},{entryId:'gh',code:'222222',receivedAt:20,expiresAt:100},{entryId:'amz',code:'333333',receivedAt:30,expiresAt:100},{entryId:'gh',code:'999999',receivedAt:40,expiresAt:30}];
 const {source:s,reads}=source({'/v1/manage/active-codes':()=>ok({records:recs})},undefined,{clock:()=>50});
 assert.deepEqual(await s.code('gh'),{entryId:'gh',code:'222222',receivedAt:20,expiresAt:100});
 recs=[];await assert.rejects(s.code('gh'));assert.equal(reads.length,3,'no received record: one on-demand generated read (unrouted here, so none)');
 for(const bad of ['',5,'a b',null,'x'.repeat(129)])await assert.rejects(s.code(bad));
});
test('inert with the existing glue: no source answers none; with this source the fill rules still decide (one fresh match, exact host)',async()=>{
 const now=1000000,{source:s}=source({'/v1/manage/entries':entries,'/v1/manage/entry/domains':ok({associations:[]}),'/v1/manage/active-codes':ok({records:[{entryId:'gh',code:'123456',receivedAt:now-1000,expiresAt:now+20000}]})},undefined,{clock:()=>now});
 const sender=u=>({id:'ext',tab:{id:1,active:true},url:u,frameId:0}),msg={type:'otpanda-fill-request'};
 const run=u=>handleFillRequest({message:msg,sender:sender(u),entries:()=>s.entries(),codes:id=>s.code(id),clock:()=>now,extensionId:'ext'});
 assert.deepEqual(await run('https://github.com/login'),{status:'ok',code:'123456',expiresAt:now+20000});
 for(const u of ['https://www.github.com/','https://github.com.evil.example/','http://github.com/','https://example.com/'])assert.deepEqual(await run(u),{status:'none'},u);
 let listener;const bg=createBackground({chromeApi:{runtime:{id:'ext',onMessage:{addListener:f=>{listener=f;}}},permissions:{getAll:async()=>({origins:[]}),contains:async()=>false},scripting:{unregisterContentScripts:async()=>{},registerContentScripts:async()=>{throw Error('must not register');}}},source:s,clock:()=>now});
 assert.equal((await bg.syncContentScripts()).registered,0,'no host permission granted: nothing is registered');
});
test('catalogue download is bounded: content-length precheck, stream abort past the cap, no full buffering',async()=>{
 const {readBounded}=await import('../src/code-source.js');const enc=new TextEncoder();
 const stream=(chunks,state)=>({headers:{get:()=>null},body:{getReader(){let i=0;return{read:async()=>{state.reads=(state.reads||0)+1;return i<chunks.length?{done:false,value:chunks[i++]}:{done:true};},cancel:async()=>{state.cancelled=true;}};}},text:async()=>{throw Error('text() must not be used');}});
 const ok={};assert.equal(await readBounded(stream([enc.encode('ab'),enc.encode('cd')],ok),10),'abcd');
 const big={};await assert.rejects(readBounded(stream(Array.from({length:1000},()=>new Uint8Array(4)),big),10),/size/);assert.equal(big.cancelled,true);assert.ok(big.reads<=4,'aborted after the cap, not read to the end');
 let touched=false;await assert.rejects(readBounded({headers:{get:()=>'99'},get body(){touched=true;return undefined;},text:async()=>'x'},10),/size/);assert.equal(touched,false,'precheck refuses before touching the body');
 await assert.rejects(readBounded(stream([new Uint8Array([0xff,0xfe])],{}),10));
 assert.equal(await readBounded({text:async()=>'plain'},10),'plain');await assert.rejects(readBounded({text:async()=>'x'.repeat(11)},10),/size/);
});
