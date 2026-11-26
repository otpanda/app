const {test}=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');
const boot=fs.readFileSync('tool/session-bootstrap.js','utf8');
function load(search,hash){
  const calls=[],location={origin:'https://otpanda.github.io',pathname:'/app/',search,hash,assign(){}},hints=new Map(),sess=new Map();
  const ctx={AbortController,setTimeout,clearTimeout,URL,URLSearchParams,TextEncoder,TextDecoder,Uint8Array,crypto:require('node:crypto').webcrypto,atob:s=>Buffer.from(s,'base64').toString('binary'),btoa:s=>Buffer.from(s,'binary').toString('base64'),
    localStorage:{getItem:k=>hints.get(k)??null,setItem:(k,v)=>hints.set(k,v),removeItem:k=>hints.delete(k)},sessionStorage:{getItem:k=>sess.get(k)??null,setItem:(k,v)=>sess.set(k,v),removeItem:k=>sess.delete(k)},
    history:{replaceState(a,b,u){calls.push(u);const q=u.indexOf('#');location.search='';location.hash=q<0?'':u.slice(q);},pushState(){}},location,
    fetch:async()=>{throw Error('no network')},addEventListener(){},document:{}};
  ctx.globalThis=ctx;vm.createContext(ctx);vm.runInContext(boot,ctx);return {ctx,calls,location};
}
for(const v of ['connected','refused'])test('marker '+v+' is read once, then stripped and cleared',async()=>{
  const e=load('?gmail='+v,'#/sources');assert.equal(e.location.search,'');assert.deepEqual(e.calls,['/app/#/sources']);
  assert.equal(await e.ctx.OTPandaSession.takeGmailResult(),v);assert.equal(await e.ctx.OTPandaSession.takeGmailResult(),'');});
for(const [s,h] of [['?gmail=other','#/sources'],['?gmail=connected&x=1','#/sources'],['?gmail=connected','#/codes'],['?gmail=connected',''],['','#/sources']])test('unrecognized or unrelated '+s+h+' yields no result and no URL rewrite',async()=>{
  const e=load(s,h);assert.equal(await e.ctx.OTPandaSession.takeGmailResult(),'');assert.equal(e.calls.filter(u=>u==='/app/#/sources'&&s).length,0);});
