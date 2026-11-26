import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {bundle} from '../build-content.mjs';
// The shipped artifact: the bundle is a CLASSIC script (no import/export), run here in a fresh vm context with a fake page.
test('the built content script is a classic script that asks with an argument-free message, fills once, never reads the page URL, tolerates a dead worker',async()=>{
 const code=bundle();assert.ok(!/^\s*(import|export)\s/m.test(code));
 const sent=[],listeners={};let mo,mode='ok';
 const el={tagName:'INPUT',attrs:{type:'text',autocomplete:'one-time-code'},value:'',isConnected:true,getAttribute(n){return n in this.attrs?this.attrs[n]:null;},dispatchEvent(){return true;},getBoundingClientRect:()=>({width:10,height:10})};
 const ctx={Date,setTimeout,clearTimeout,Promise,Object,Number,String,Event:class{constructor(t){this.type=t;}},
  MutationObserver:class{constructor(f){mo=f;}observe(){}},getComputedStyle:()=>({visibility:'visible',display:'block',opacity:'1',pointerEvents:'auto'}),
  chrome:{runtime:{sendMessage:async m=>{sent.push(m);if(mode==='dead')throw new Error('gone');return{status:'ok',expiresAt:9999999999999,code:'123456'};}}},
  document:{visibilityState:'visible',hasFocus:()=>true,querySelectorAll:s=>s==='input'?[el]:[],addEventListener:(t,f)=>{listeners['d:'+t]=f;}},
  addEventListener:(t,f)=>{listeners[t]=f;}};
 ctx.globalThis=ctx;ctx.top=ctx;Object.defineProperty(ctx,'location',{get(){throw new Error('content script must not read location');}});
 vm.createContext(ctx);vm.runInContext(code,ctx);
 const tick=()=>new Promise(r=>setTimeout(r,10));await tick();
 assert.equal(JSON.stringify(sent),'[{"type":"otpanda-fill-request"}]');assert.equal(el.value,'123456');
 assert.ok(listeners['d:visibilitychange']&&listeners.focus&&listeners.pagehide&&listeners.pageshow&&mo);
 mo();await tick();assert.equal(el.value,'123456');assert.equal(sent.length,1,'a filled field asks for nothing more');
});
