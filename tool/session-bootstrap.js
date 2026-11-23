/* Runs before Flutter or any other app script. Access stays in this closure. */
(() => {
  'use strict';
  const API = 'https://otpanda-api.abrahammurciano.workers.dev';
  const REDIRECT = 'https://otpanda.github.io/app/';
  const KEY = 'otpanda.restore.tab.v1';
  let access, expires = 0, status = 'idle', generation = 0;
  const encode = bytes => btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
  const random = () => encode(crypto.getRandomValues(new Uint8Array(32)));
  const clear = () => { generation++; access = undefined; expires = 0; };
  const pending = location.hash;
  // Callback fragment is always removed before a promise, fetch or Flutter load.
  if (pending) history.replaceState(null, '', location.pathname + location.search);
  let saved;
  if (pending) { try { saved = sessionStorage.getItem(KEY); sessionStorage.removeItem(KEY); } catch {} }
  const ready = (async () => {
    if (!pending) return;
    status = 'restoring';const attempt=generation;
    try {
      if (location.origin + location.pathname !== REDIRECT || location.search || pending.length > 1024 || !saved) throw Error();
      const values = new URLSearchParams(pending.slice(1));
      if ([...values.keys()].sort().join(',') !== 'code,state') throw Error();
      const code = values.get('code'), state = values.get('state'), p = JSON.parse(saved), now = Date.now();
      if (!/^otpda_[A-Za-z0-9_-]{55}$/.test(code) || !/^[A-Za-z0-9_-]{43}$/.test(state) || state !== p.state || !/^[A-Za-z0-9_-]{43}$/.test(p.verifier) || !Number.isSafeInteger(p.created) || now < p.created || now-p.created > 300000) throw Error();
      const response = await fetch(API+'/auth/exchange', {method:'POST', credentials:'omit', cache:'no-store', redirect:'error', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code,verifier:p.verifier,redirect_uri:REDIRECT})});
      if (!response.ok) throw Error();
      const text = await response.text(); if (text.length > 2048) throw Error();
      const result = JSON.parse(text);
      if (Object.keys(result).sort().join(',') !== 'access,accessExpiresAt' || !/^otpda_[A-Za-z0-9_-]{55}$/.test(result.access) || !Number.isSafeInteger(result.accessExpiresAt) || result.accessExpiresAt <= Date.now() || result.accessExpiresAt > Date.now()+300000) throw Error();
      if(attempt!==generation)return;
      access = result.access; expires=result.accessExpiresAt;status='restored';
    } catch { if(attempt===generation){clear();status='sign-in-required';} }
  })();
  Object.defineProperty(globalThis,'OTPandaSession',{value:Object.freeze({
    ready,
    status:()=>status,
    access:()=>{if(Date.now()>=expires)clear();return access;},
    clear:()=>{clear();status='idle';try{sessionStorage.removeItem(KEY);}catch{}},
    start:async()=>{
      if(location.origin+location.pathname!==REDIRECT||location.search)throw Error('Canonical app URL required');
      clear();const attempt=generation,verifier=random(),state=random(),challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
      if(attempt!==generation)return;
      sessionStorage.setItem(KEY,JSON.stringify({verifier,state,created:Date.now()}));
      const url=new URL(API+'/auth/restore');url.search=new URLSearchParams({challenge,state,redirect_uri:REDIRECT});location.assign(url.href);
    },
  }),writable:false,configurable:false});
})();
