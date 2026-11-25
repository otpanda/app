import test from 'node:test';
import assert from 'node:assert/strict';
test('content script asks with an argument-free message, fills once, never reads the page URL, tolerates a dead worker',async()=>{
 const sent=[];const el={tagName:'INPUT',attrs:{type:'text',autocomplete:'one-time-code'},value:'',getAttribute(n){return n in this.attrs?this.attrs[n]:null;},dispatchEvent(){return true;},getBoundingClientRect:()=>({width:10,height:10})};
 let mo;globalThis.MutationObserver=class{constructor(f){mo=f;}observe(){}};
 globalThis.getComputedStyle=()=>({visibility:'visible'});globalThis.Event=class{constructor(t){this.type=t;}};
 let mode='ok';globalThis.chrome={runtime:{sendMessage:async m=>{sent.push(m);if(mode==='dead')throw new Error('gone');return{status:'ok',code:'123456'};}}};
 Object.defineProperty(globalThis,'location',{get(){throw new Error('content script must not read location');},configurable:true});
 globalThis.document={querySelectorAll:s=>s==='input'?[el]:[]};
 await import('../src/content.js');await new Promise(r=>setTimeout(r,10));
 assert.deepEqual(sent,[{type:'otpanda-fill-request'}]);assert.equal(el.value,'123456');
 mo();await new Promise(r=>setTimeout(r,10));assert.equal(el.value,'123456');
 el.value='';mode='dead';mo();await new Promise(r=>setTimeout(r,10));assert.equal(el.value,'');
});
