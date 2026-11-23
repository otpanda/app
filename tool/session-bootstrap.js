/* Runs before Flutter or any other app script. Access stays in this closure. */
(() => {
  'use strict';
  const API = 'https://otpanda-api.abrahammurciano.workers.dev';
  const REDIRECT = 'https://otpanda.github.io/app/';
  const KEY = 'otpanda.restore.tab.v1';
  let access, expires = 0, status = 'idle', generation = 0, loginPending;
  const encode = bytes => btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
  const random = () => encode(crypto.getRandomValues(new Uint8Array(32)));
  const clear = () => { generation++; access = undefined; expires = 0; loginPending=undefined; };
  // Bound bytes as they arrive. A post-buffer string length check is too late.
  const readBounded = async (response, limit) => {
    const advertised=response.headers?.get('content-length');
    if(advertised!==null&&advertised!==undefined&&(!/^[0-9]+$/.test(advertised)||Number(advertised)>limit))throw Error('Response too large');
    if(!response.body?.getReader)throw Error('Readable response required');
    const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});let size=0,text='';
    try {while(true){const {done,value}=await reader.read();if(done)break;if(!(value instanceof Uint8Array))throw Error('Byte stream required');size+=value.byteLength;if(size>limit)throw Error('Response too large');text+=decoder.decode(value,{stream:true});}return text+decoder.decode();}
    catch(error){try{await reader.cancel();}catch{}throw error;}
    finally{reader.releaseLock();}
  };
  const pending = location.hash;
  // Callback fragment is always removed before a promise, fetch or Flutter load.
  if (pending) history.replaceState(null, '', location.pathname + location.search);
  let saved;
  if (pending) { try { saved = sessionStorage.getItem(KEY); sessionStorage.removeItem(KEY); } catch {} }
  const ready = (async () => {
    if (!pending) return;
    status = 'restoring';const attempt=generation;
    try {
      if (location.origin + location.pathname !== REDIRECT || location.search || pending.length > 8192 || !saved) throw Error();
      const values = new URLSearchParams(pending.slice(1));
      const state=values.get('state'),p=JSON.parse(saved),now=Date.now();
      if(!/^[A-Za-z0-9_-]{43}$/.test(state)||state!==p.state||!/^[A-Za-z0-9_-]{43}$/.test(p.verifier)||!Number.isSafeInteger(p.created)||now<p.created||now-p.created>300000)throw Error();
      if([...values.keys()].sort().join(',')==='login,state'){
        const encoded=values.get('login');if(!/^[A-Za-z0-9_-]{1,6000}$/.test(encoded))throw Error();
        const c=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(atob(encoded.replaceAll('-','+').replaceAll('_','/')),v=>v.charCodeAt(0))));
        if(Object.keys(c).sort().join(',')!=='expiresAt,options,token'||!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||!Number.isSafeInteger(c.expiresAt)||c.expiresAt<=now||c.expiresAt>now+120000)throw Error();
        const o=c.options;if(!o||Object.keys(o).some(k=>!['rpId','challenge','timeout','userVerification','allowCredentials','extensions'].includes(k))||o.rpId!=='otpanda.github.io'||o.userVerification!=='required'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||o.timeout!==120000||(o.allowCredentials!==undefined&&(!Array.isArray(o.allowCredentials)||o.allowCredentials.length))||(o.extensions!==undefined&&Object.keys(o.extensions).length))throw Error();
        loginPending={ceremony:c,saved:p};status='passkey-ready';return;
      }
      if ([...values.keys()].sort().join(',') !== 'code,state') throw Error();
      const code=values.get('code');if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(code))throw Error();
      const response = await fetch(API+'/auth/exchange', {method:'POST', credentials:'omit', cache:'no-store', redirect:'error', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code,verifier:p.verifier,redirect_uri:REDIRECT})});
      if (!response.ok) throw Error();
      const text = await readBounded(response,2048);
      const result = JSON.parse(text);
      if (Object.keys(result).sort().join(',') !== 'access,accessExpiresAt' || !/^otpda_[A-Za-z0-9_-]{55}$/.test(result.access) || !Number.isSafeInteger(result.accessExpiresAt) || result.accessExpiresAt <= Date.now() || result.accessExpiresAt > Date.now()+300000) throw Error();
      if(attempt!==generation)return;
      access = result.access; expires=result.accessExpiresAt;status='restored';
    } catch { if(attempt===generation){clear();status='sign-in-required';} }
  })();
  Object.defineProperty(globalThis,'OTPandaSession',{value:Object.freeze({
    ready,
    status:()=>status,
    access:()=>{if(access!==undefined&&Date.now()>=expires){clear();status='sign-in-required';}return access;},
    clear:()=>{clear();status='idle';try{sessionStorage.removeItem(KEY);}catch{}},
    logout:()=>{clear();status='idle';try{sessionStorage.removeItem(KEY);}catch{}location.assign(API+'/auth/device/logout');},
    read:async path=>{
      if(!['/v1/manage/session','/v1/manage/entries','/v1/manage/active-codes'].includes(path))throw Error('Read path required');
      const attempt=generation,token=Date.now()<expires?access:undefined;if(!token){if(access!==undefined){clear();status='sign-in-required';}return {status:401,body:'{}'};}
      const r=await fetch(API+path,{method:'GET',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token}});const body=await readBounded(r,524288);
      if(attempt!==generation)return {status:401,body:'{}'};
      if(r.status===401){clear();status='sign-in-required';}
      return {status:r.status,body};
    },
    passkey:async()=>{
      const pending=loginPending;if(!pending||status!=='passkey-ready')throw Error('Start sign-in again');
      loginPending=undefined;const attempt=++generation;status='authenticating';
      try{
        if(pending.ceremony.expiresAt<=Date.now()||Date.now()-pending.saved.created>300000)throw Error();
        const decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
        const o=pending.ceremony.options,c=await navigator.credentials.get({publicKey:{rpId:'otpanda.github.io',challenge:decode(o.challenge),timeout:Math.min(120000,pending.ceremony.expiresAt-Date.now()),userVerification:'required'}});
        if(attempt!==generation)return;
        if(!c||c.type!=='public-key')throw Error();
        const response={id:c.id,rawId:encode(new Uint8Array(c.rawId)),type:c.type,clientExtensionResults:c.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(c.response.clientDataJSON)),authenticatorData:encode(new Uint8Array(c.response.authenticatorData)),signature:encode(new Uint8Array(c.response.signature)),userHandle:c.response.userHandle?encode(new Uint8Array(c.response.userHandle)):null}};
        const r=await fetch(API+'/auth/login/verify',{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:pending.ceremony.token,response})});if(!r.ok)throw Error();const text=await readBounded(r,2048);const result=JSON.parse(text);
        if(Object.keys(result).sort().join(',')!=='expiresAt,handoff'||!/^otpda_[A-Za-z0-9_-]{55}$/.test(result.handoff)||!Number.isSafeInteger(result.expiresAt)||result.expiresAt<=Date.now()||result.expiresAt>Date.now()+60000)throw Error();
        if(attempt!==generation)return;
        sessionStorage.setItem(KEY,JSON.stringify(pending.saved));status='completing';location.assign(API+'/auth/login/complete#'+new URLSearchParams({handoff:result.handoff}));
      }catch{if(attempt===generation){clear();status='sign-in-required';}}
    },
    start:async(mode='restore')=>{
      if(location.origin+location.pathname!==REDIRECT||location.search)throw Error('Canonical app URL required');
      if(!['restore','login'].includes(mode))throw Error('Known session flow required');
      clear();const attempt=generation,verifier=random(),state=random(),challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
      if(attempt!==generation)return;
      sessionStorage.setItem(KEY,JSON.stringify({verifier,state,created:Date.now()}));
      const url=new URL(API+(mode==='login'?'/auth/login/start':'/auth/restore'));url.search=new URLSearchParams({challenge,state,redirect_uri:REDIRECT});location.assign(url.href);
    },
  }),writable:false,configurable:false});
})();
