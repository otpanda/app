import test from 'node:test';
import assert from 'node:assert/strict';
import { handleFillRequest, FRESH_MS } from '../src/fill-request.js';
const NOW=1_800_000_000_000,ID='ext-id',entries=async()=>[{entryId:'gh',domains:['github.com']},{entryId:'gh2',domains:['github.com']},{entryId:'x',domains:['example.com']}];
const sender=(o={})=>({id:ID,tab:{id:1},url:'https://github.com/sessions/two-factor',frameId:0,...o}),msg={type:'otpanda-fill-request'};
const code=(entryId,o={})=>({entryId,code:'123456',receivedAt:NOW-1000,expiresAt:NOW+60000,...o});
const run=(codes,o={})=>handleFillRequest({message:msg,sender:sender(),entries,codes,clock:()=>NOW,extensionId:ID,...o});
test('one eligible entry with a fresh code releases it to the requesting frame only',async()=>{
 const asked=[];const r=await run(async id=>{asked.push(id);return id==='gh'?code('gh'):undefined;});
 assert.deepEqual(r,{status:'ok',code:'123456',expiresAt:NOW+60000});assert.deepEqual(asked.sort(),['gh','gh2'],'only eligible entries are asked');
});
test('the page host comes from the sender, never the message: extra fields, wrong sender id, missing tab/url/frame, non-https, lookalike hosts release nothing',async()=>{
 const ok=async()=>code('gh');
 for(const m of [{...msg,url:'https://github.com/'},{type:'other'},null,{}])assert.equal((await handleFillRequest({message:m,sender:sender(),entries,codes:ok,clock:()=>NOW,extensionId:ID})).status,'none');
 for(const s of [sender({id:'other'}),sender({tab:undefined}),sender({url:undefined}),sender({frameId:undefined}),sender({url:'http://github.com/'}),sender({url:'https://github.com.evil.example/'}),sender({url:'https://www.github.com/'}),null])assert.equal((await handleFillRequest({message:msg,sender:s,entries,codes:ok,clock:()=>NOW,extensionId:ID})).status,'none');
});
test('stale, future, expired, mismatched or malformed codes are never released; two fresh candidates are ambiguous and release nothing',async()=>{
 for(const c of [code('gh',{receivedAt:NOW-FRESH_MS-1}),code('gh',{expiresAt:NOW}),code('gh',{receivedAt:NOW+1}),code('other'),code('gh',{code:'<script>'}),code('gh',{code:'1'}),{entryId:'gh'}])assert.equal((await run(async id=>id==='gh'?c:undefined)).status,'none',JSON.stringify(c));
 const r=await run(async id=>code(id));assert.deepEqual(r,{status:'ambiguous',count:2});assert.equal(r.code,undefined);
 assert.equal((await run(async()=>{throw new Error('x');})).status,'none');
});
