import test from 'node:test';
import assert from 'node:assert/strict';
import { createBackground, SCRIPT_ID } from '../src/background.js';
const NOW=1_800_000_000_000;
function chromeFake({granted=true}={}){const c={listener:null,reg:[],unreg:0,asked:[],runtime:{id:'ext',onMessage:{addListener(f){c.listener=f;}}},
 permissions:{contains:async p=>{c.asked.push(p.origins);return granted;}},scripting:{unregisterContentScripts:async()=>{c.unreg++;},registerContentScripts:async s=>{c.reg.push(...s);}}};return c;}
const ask=(c,sender,msg={type:'otpanda-fill-request'})=>new Promise(res=>{const keep=c.listener(msg,sender,res);if(keep===false)return;});
const source=()=>({entries:async()=>[{entryId:'gh',domains:['github.com']}],code:async id=>({entryId:id,code:'123456',receivedAt:NOW-1,expiresAt:NOW+9999})});
const sender={id:'ext',tab:{id:1},url:'https://github.com/x',frameId:0};
test('without a source it is inert: no registration and no code',async()=>{
 const c=chromeFake();const b=createBackground({chromeApi:c});assert.deepEqual(await ask(c,sender),{status:'none'});assert.deepEqual(await b.syncContentScripts(),{registered:0});assert.equal(c.reg.length,0);
});
test('a fill request is answered from the browser-provided sender, async response kept open',async()=>{
 const c=chromeFake();createBackground({chromeApi:c,source:source(),clock:()=>NOW});
 let kept;const p=new Promise(res=>{kept=c.listener({type:'otpanda-fill-request'},sender,res);});assert.equal(kept,true);assert.equal((await p).status,'ok');
 assert.equal((await ask(c,{...sender,url:'https://github.com.evil.example/'})).status,'none');
 assert.equal((await ask(c,{...sender,id:'someone-else'})).status,'none');
});
test('content script registered only on exact-host patterns and only when the optional permission is already granted; never broad',async()=>{
 const c=chromeFake({granted:true});const b=createBackground({chromeApi:c,source:source(),clock:()=>NOW});
 assert.deepEqual(await b.syncContentScripts(),{registered:1});assert.deepEqual(c.asked[0],['https://github.com/*']);
 assert.equal(c.reg[0].id,SCRIPT_ID);assert.deepEqual(c.reg[0].matches,['https://github.com/*']);assert.equal(c.reg[0].matchOriginAsFallback,false);
 const d=chromeFake({granted:false});const bd=createBackground({chromeApi:d,source:source()});assert.deepEqual(await bd.syncContentScripts(),{registered:0});assert.equal(d.reg.length,0);assert.equal(d.unreg,1,'stale registration removed');
 const e=chromeFake();const be=createBackground({chromeApi:e,source:{entries:async()=>[{entryId:'x',domains:['*.com','http://a.com']}],code:async()=>undefined}});assert.deepEqual(await be.syncContentScripts(),{registered:0});assert.equal(e.reg.length,0);
});
