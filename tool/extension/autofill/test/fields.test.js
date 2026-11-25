import test from 'node:test';
import assert from 'node:assert/strict';
import { isOtpField, findOtpTargets, fillTarget, validCode } from '../src/fields.js';
class Ev{constructor(t,o){this.type=t;this.o=o;}}
function input(a={},parent=null){const el={tagName:'INPUT',attrs:a,value:'',events:[],parentElement:parent,disabled:a.disabled,readOnly:a.readOnly,getAttribute(n){return n in this.attrs?this.attrs[n]:null;},dispatchEvent(e){this.events.push(e.type+':'+this.value);return true;}};return el;}
const root=els=>({querySelectorAll:s=>s==='input'?els:[]});
const setter=(e,v)=>{e.value=v;};
test('detects OTP fields by autocomplete/name/label and rejects password, email, search, card, hidden, disabled, wrong types',()=>{
 assert.ok(isOtpField(input({type:'text',autocomplete:'one-time-code'})));
 assert.ok(isOtpField(input({type:'tel',name:'otp',maxlength:'6'})));
 assert.ok(isOtpField(input({type:'text','aria-label':'Verification code'})));
 for(const a of [{type:'password',name:'password'},{type:'password',name:'otp'},{type:'email',name:'otp'},{type:'text',name:'email_verification'},{type:'text',name:'search'},{type:'text',name:'card_code'},{type:'text',name:'q'},{type:'text',name:'otp',maxlength:'40'},{type:'hidden',name:'otp'},{type:'text',name:'otp',disabled:true},{type:'text',name:'otp',readOnly:true},{type:'text',name:'username',autocomplete:'username'}])assert.equal(isOtpField(input(a)),false,JSON.stringify(a));
 assert.equal(isOtpField(input({type:'text',name:'otp'}),{visible:()=>false}),false);assert.equal(isOtpField(null),false);assert.equal(isOtpField({tagName:'DIV'}),false);
});
test('groups: a single field, or 4-10 maxlength=1 siblings; unrelated singles are not grouped',()=>{
 const p={},boxes=Array.from({length:6},()=>input({type:'text',name:'otp',maxlength:'1'},p));
 const g=findOtpTargets(root([...boxes,input({type:'text',name:'q'})]));assert.equal(g.length,1);assert.equal(g[0].length,6);
 assert.equal(findOtpTargets(root([input({type:'text',name:'otp',maxlength:'1'},{}),input({type:'text',name:'otp',maxlength:'1'},{})])).length,0);
 assert.equal(findOtpTargets(root([input({type:'text',autocomplete:'one-time-code'})])).length,1);
});
test('fill sets value and fires input+change; split boxes get one digit each; invalid or non-fitting codes fill nothing',()=>{
 const a=input({type:'text',name:'otp',maxlength:'6'});assert.equal(fillTarget([a],'123456',{setter,}),true);assert.equal(a.value,'123456');
 const g=globalThis.Event;globalThis.Event=Ev;try{
  const b=input({type:'text',name:'otp'});assert.ok(fillTarget([b],'654321',{setter}));assert.deepEqual(b.events,['input:654321','change:654321']);
  const p={},bs=Array.from({length:6},()=>input({type:'text',name:'otp',maxlength:'1'},p));assert.ok(fillTarget(bs,'123-456',{setter}));assert.equal(bs.map(x=>x.value).join(''),'123456');
  const c=input({type:'text',name:'otp',maxlength:'4'});assert.equal(fillTarget([c],'123456',{setter}),false);assert.equal(c.value,'');
  const d=input({type:'text',name:'otp'});for(const bad of ['<img onerror=1>','12','',null,'1 2 3 4',"a'b"])assert.equal(fillTarget([d],bad,{setter}),false);assert.equal(d.value,'');
  assert.equal(fillTarget(bs,'12345',{setter}),false);assert.equal(fillTarget([],'123456'),false);
 }finally{globalThis.Event=g;}
 assert.ok(validCode('ABC-123')&&!validCode('a b'));
});
