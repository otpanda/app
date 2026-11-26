import test from 'node:test';
import assert from 'node:assert/strict';
import {createContentController,MIN_GAP_MS} from '../src/content-core.js';
function env(o={}){
 const sent=[],timers=[];let now=1_000_000;
 const el={tagName:'INPUT',attrs:{type:'text',autocomplete:'one-time-code'},value:'',isConnected:true,rect:{width:20,height:20},sty:{visibility:'visible',display:'block',opacity:'1',pointerEvents:'auto'},
  getAttribute(n){return n in this.attrs?this.attrs[n]:null;},dispatchEvent(){return true;},getBoundingClientRect(){return this.rect;}};
 const doc={visibilityState:'visible',focused:true,hasFocus(){return this.focused;},querySelectorAll:s=>s==='input'?[el]:[]};
 const win=o.win??{};win.top??=win;
 const state={reply:{status:'ok',expiresAt:9999999999999,code:'111111'},hold:undefined,throwNext:false};
 globalThis.Event??=class{constructor(t){this.type=t;}};
 const c=createContentController({doc,win,now:()=>now,setTimer:(f,ms)=>{timers.push({f,at:now+ms});return timers.length;},clearTimer:id=>{timers[id-1]=undefined;},style:e=>e.sty,
  send:async()=>{sent.push(now);if(state.throwNext)throw Error('x');if(state.hold)await state.hold;return state.reply;}});
 const tick=()=>new Promise(r=>setTimeout(r,2));
 return {sent,timers,el,doc,win,c,state,tick,adv:ms=>{now+=ms;},due:()=>timers.filter(t=>t&&t.at<=now)};
}
test('a visible focused top-frame page with an empty rendered OTP field asks once and fills',async()=>{
 const e=env();await e.c.attempt();assert.equal(e.sent.length,1);assert.equal(e.el.value,'111111');
});
test('hidden, background or unfocused pages never ask; becoming foreground asks',async()=>{
 const e=env();e.doc.visibilityState='hidden';await e.c.attempt();assert.equal(e.sent.length,0);
 e.doc.visibilityState='visible';e.doc.focused=false;await e.c.attempt();assert.equal(e.sent.length,0);
 e.doc.focused=true;await e.c.attempt();assert.equal(e.sent.length,1);
 const noFocusApi=env();noFocusApi.doc.hasFocus=undefined;await noFocusApi.c.attempt();assert.equal(noFocusApi.sent.length,0,'unknown focus fails closed');
});
test('the code is dropped when the page goes to the background, loses focus, or the field changes while the worker answers',async()=>{
 for(const change of [e=>{e.doc.visibilityState='hidden';},e=>{e.doc.focused=false;},e=>{e.el.value='user typed';},e=>{e.el.isConnected=false;}]){
  const e=env();let release;e.state.hold=new Promise(r=>{release=r;});const p=e.c.attempt();await e.tick();assert.equal(e.sent.length,1);
  change(e);release();await p;assert.notEqual(e.el.value,'111111');
 }
});
test('never overwrites a value and asks nothing while a field is filled; cleared again it can ask after the gap',async()=>{
 const e=env();e.el.value='999999';await e.c.attempt();assert.equal(e.sent.length,0);assert.equal(e.el.value,'999999');
 e.el.value='';e.state.reply={status:'ok',expiresAt:9999999999999,code:'222222'};await e.c.attempt();assert.equal(e.el.value,'222222');
 e.el.value='';e.adv(MIN_GAP_MS+1);e.state.reply={status:'ok',expiresAt:9999999999999,code:'333333'};await e.c.attempt();assert.equal(e.el.value,'333333');
});
test('tiny, transparent, display:none, pointer-events:none and hidden fields are not targets',async()=>{
 for(const patch of [e=>{e.el.rect={width:1,height:1};},e=>{e.el.sty.opacity='0';},e=>{e.el.sty.display='none';},e=>{e.el.sty.pointerEvents='none';},e=>{e.el.sty.visibility='hidden';},e=>{e.el.attrs.type='password';e.el.attrs.autocomplete='current-password';}]){
  const e=env();patch(e);await e.c.attempt();assert.equal(e.sent.length,0);
 }
});
test('frames: top and same-origin-ancestor frames are fine; cross-origin, unknown or empty ancestry fails closed',async()=>{
 const frame=anc=>({top:{},location:{origin:'https://github.com',ancestorOrigins:anc}});
 for(const [anc,ok] of [[['https://github.com'],true],[['https://github.com','https://github.com'],true],[['https://evil.example'],false],[['https://github.com','https://evil.example'],false],[[],false],[undefined,false]]){
  const e=env({win:frame(anc)});await e.c.attempt();assert.equal(e.sent.length,ok?1:0,JSON.stringify(anc));
 }
});
test('requests are spaced: a storm inside the gap, and mutations during a request, make one trailing attempt that rechecks',async()=>{
 const e=env();let release;e.state.hold=new Promise(r=>{release=r;});
 const p=e.c.attempt();await e.tick();for(let i=0;i<300;i++)e.c.attempt();assert.equal(e.sent.length,1,'busy: no second request');
 e.state.reply={status:'none'};release();await p;await e.tick();assert.equal(e.timers.filter(Boolean).length,1,'a busy-window mutation leaves exactly one trailing attempt');
 for(let i=0;i<300;i++)e.c.attempt();await e.tick();assert.equal(e.timers.filter(Boolean).length,1);assert.equal(e.sent.length,1);
 e.adv(MIN_GAP_MS);e.state.hold=undefined;e.state.reply={status:'ok',expiresAt:9999999999999,code:'444444'};await e.due()[0].f();await e.tick();assert.equal(e.sent.length,2);assert.equal(e.el.value,'444444');
});
test('a trailing attempt that fires after the page was hidden asks nothing',async()=>{
 const e=env();e.state.reply={status:'none'};await e.c.attempt();for(let i=0;i<5;i++)e.c.attempt();
 e.doc.visibilityState='hidden';e.adv(MIN_GAP_MS);await e.due()[0].f();await e.tick();assert.equal(e.sent.length,1);
});
test('pagehide cancels the timer and blocks asks until pageshow; a dead worker is tolerated',async()=>{
 const e=env();e.state.reply={status:'none'};await e.c.attempt();e.c.attempt();await e.tick();
 e.c.pagehide();assert.equal(e.timers.filter(Boolean).length,0);e.adv(MIN_GAP_MS);await e.c.attempt();assert.equal(e.sent.length,1);
 e.state.throwNext=true;e.c.pageshow();await e.tick();assert.equal(e.sent.length,2);assert.equal(e.el.value,'');
});
test('a repeated identical code is not filled again after the user clears the field',async()=>{
 const e=env();await e.c.attempt();assert.equal(e.el.value,'111111');e.el.value='';e.adv(MIN_GAP_MS+1);await e.c.attempt();assert.equal(e.el.value,'','same code is not re-filled');
});

test('an answer that expires while waiting never reaches the field',async()=>{const e=env();e.state.reply={status:'ok',code:'123456',expiresAt:1};await e.c.attempt();assert.equal(e.el.value,'');});
