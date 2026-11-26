import test from 'node:test';
import assert from 'node:assert/strict';
import {createCodeSource} from '../src/code-source.js';
import {handleFillRequest} from '../src/fill-request.js';
const ok=o=>({status:200,body:JSON.stringify(o)});
const gen=(id,o={})=>ok({entryId:id,code:'94287082',period:30,validFrom:30,validUntil:60,serverNow:59000,...o});
// mono advances by `rtt` ms across each generated read; wall clock is separate and can jump.
function rig({routes={},rtt=0,wall=1_000_000}={}){
 let m=0,w=wall;const reads=[];
 const read=async p=>{reads.push(p);const r=routes[p.split('?')[0]];const v=typeof r==='function'?r(p):r;m+=p.includes('totp-code')?rtt:0;return v??{status:503,body:'{}'};};
 const s=createCodeSource({read,catalogue:{rows:async()=>undefined},clock:()=>w,mono:()=>m});
 return {s,reads,adv:ms=>{m+=ms;},jump:ms=>{w+=ms;},now:()=>w};
}
const totpReads=r=>r.reads.filter(p=>p.includes('totp-code'));
test('a recent received code wins and costs no generated read',async()=>{
 const r=rig({routes:{'/v1/manage/active-codes':ok({records:[{entryId:'a',code:'111111',receivedAt:1_000_000-1000,expiresAt:1_000_000+60000}]}),'/v1/manage/totp-code':gen('a')}});
 assert.equal((await r.s.code('a')).code,'111111');assert.equal(totpReads(r).length,0);
});
test('no received record: exactly one GET for exactly that entry, strict query, code only (no seed fields)',async()=>{
 const r=rig({routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':p=>gen(p.split('=')[1])}});
 const c=await r.s.code('a_B-9');assert.deepEqual(totpReads(r),['/v1/manage/totp-code?entry=a_B-9']);
 assert.deepEqual(Object.keys(c).sort(),['code','entryId','expiresAt','receivedAt']);assert.equal(c.code,'94287082');
});
test('freshness: remaining = server window minus the FULL round trip (monotonic); the code is dead when the trip eats the window',async()=>{
 let r=rig({rtt:300,routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':gen('a')}});
 let c=await r.s.code('a');assert.equal(c.expiresAt-r.now(),1000-300,'server says 1000ms left; minus rtt 300');assert.equal(r.now()-c.receivedAt,29000+300,'age = server age + rtt');
 r=rig({rtt:1000,routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':gen('a')}});await assert.rejects(r.s.code('a'),/expired/);
 r=rig({rtt:1500,routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':gen('a')}});await assert.rejects(r.s.code('a'));
});
test('a wall-clock jump during the call cannot extend the code; only the monotonic round trip counts',async()=>{
 const r=rig({rtt:200,routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':()=>{r.jump(3_600_000);return gen('a');}}});
 const c=await r.s.code('a');assert.equal(c.expiresAt-r.now(),800);assert.ok(c.receivedAt<=r.now());
});
test('malformed or mismatched generations are refused',async()=>{
 for(const bad of [{entryId:'other'},{code:'12ab56'},{code:'12345'},{validUntil:61},{period:0},{serverNow:29000},{serverNow:60000},{validFrom:'30'},{code:123456}]){
  const r=rig({routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':gen('a',bad)}});await assert.rejects(r.s.code('a'),JSON.stringify(bad));}
 const r=rig({routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':{status:404,body:'{"error":"not_found"}'}}});await assert.rejects(r.s.code('a'));
});
test('429 honors Retry-After on the monotonic clock: no generated read until it passes, no loop; nothing is cached',async()=>{
 let limited=true;const r=rig({routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':()=>limited?{status:429,body:'{}',retryAfter:30}:gen('a')}});
 await assert.rejects(r.s.code('a'));assert.equal(totpReads(r).length,1);
 limited=false;r.adv(29_000);await assert.rejects(r.s.code('a'),/rate/);assert.equal(totpReads(r).length,1,'still blocked at 29s');
 r.adv(1_500);assert.equal((await r.s.code('a')).code,'94287082');assert.equal(totpReads(r).length,2);
 await r.s.code('a');assert.equal(totpReads(r).length,3,'no cache: each call reads again');
});
test('missing Retry-After still blocks for 60s; a huge one is capped at an hour',async()=>{
 let ra;const r=rig({routes:{'/v1/manage/active-codes':ok({records:[]}),'/v1/manage/totp-code':()=>({status:429,body:'{}',...(ra?{retryAfter:ra}:{})})}});
 await assert.rejects(r.s.code('a'));r.adv(59_000);await assert.rejects(r.s.code('a'),/rate/);r.adv(1_500);await assert.rejects(r.s.code('a'));assert.equal(totpReads(r).length,2);
 ra=10**9;r.adv(61_000);await assert.rejects(r.s.code('a'));r.adv(3_599_000);await assert.rejects(r.s.code('a'),/rate/);r.adv(2_000);await assert.rejects(r.s.code('a'));assert.equal(totpReads(r).length,4);
});
// fill-request still decides: host match, single fresh candidate, ambiguity, expiry.
const entriesRoute=ok({entries:[{entry_id:'gh1',catalogId:'github.com'},{entry_id:'gh2',catalogId:'github.com'},{entry_id:'amz',catalogId:'amazon.com'}]});
function fill(routes,{rtt=0,url='https://github.com/login'}={}){
 const r=rig({rtt,routes:{'/v1/manage/entries':entriesRoute,'/v1/manage/entry/domains':ok({associations:[]}),'/v1/manage/active-codes':ok({records:[]}),...routes}});
 const rows=[{n:'GitHub',d:['github.com']},{n:'Amazon',d:['amazon.com']}];
 const s=createCodeSource({read:async p=>{r.reads.push(p);const x=routes[p.split('?')[0]]??({'/v1/manage/entries':entriesRoute,'/v1/manage/entry/domains':ok({associations:[]}),'/v1/manage/active-codes':ok({records:[]})})[p];return typeof x==='function'?x(p):x??{status:503,body:'{}'};},catalogue:{rows:async()=>rows},clock:()=>r.now(),mono:()=>0});
 return {r,run:()=>handleFillRequest({message:{type:'otpanda-fill-request'},sender:{id:'ext',tab:{id:1,active:true},url,frameId:0},entries:()=>s.entries(),codes:id=>s.code(id),clock:()=>r.now(),extensionId:'ext'})};
}
test('with fill-request: one matching generated entry fills; reads only for host-matched entries',async()=>{
 const {r,run}=fill({'/v1/manage/totp-code':p=>p.endsWith('=gh1')?gen('gh1'):{status:404,body:'{}'}});
 const out=await run();assert.equal(out.status,'ok');assert.equal(out.code,'94287082');
 assert.deepEqual(totpReads(r).sort(),['/v1/manage/totp-code?entry=gh1','/v1/manage/totp-code?entry=gh2'],'the amazon entry is never read for a github page');
});
test('with fill-request: two entries with fresh generated codes are ambiguous and release nothing',async()=>{
 const {run}=fill({'/v1/manage/totp-code':p=>gen(p.split('=')[1])});
 assert.deepEqual(await run(),{status:'ambiguous',count:2});
});
test('with fill-request: wrong host or non-matching page makes no generated read at all',async()=>{
 for(const url of ['https://github.com.evil.example/','http://github.com/','https://example.com/']){
  const {r,run}=fill({'/v1/manage/totp-code':p=>gen(p.split('=')[1])},{url});assert.deepEqual(await run(),{status:'none'},url);assert.equal(totpReads(r).length,0,url);}
});
