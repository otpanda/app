/* Runs before Flutter or any other app script. Access stays in this closure. */
(() => {
  'use strict';
  const API = 'https://otpanda-api.abrahammurciano.workers.dev';
  const REDIRECT = 'https://otpanda.github.io/app/';
  const KEY = 'otpanda.restore.tab.v1';
  let access, expires = 0, status = 'idle', generation = 0, loginPending, entryEmail='',enrollment,googlePending,protectionPending;
  const encode = bytes => btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
  const random = () => encode(crypto.getRandomValues(new Uint8Array(32)));
  const clear = () => { assignment?.clear();generation++; access = undefined; expires = 0; loginPending=undefined;enrollment=undefined;googlePending=undefined;protectionPending=undefined; };
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
  // Factories are loaded before this closure only in a separately enabled host.
  // No bearer or ceremony is persisted or passed to Flutter.
  const assignment=typeof globalThis.OTPandaAssignmentController==='function'&&typeof globalThis.OTPandaAssignmentTransport==='function'?new globalThis.OTPandaAssignmentController(globalThis.OTPandaAssignmentTransport({access:()=>Date.now()<expires?access:undefined,generation:()=>generation,fetchImpl:(...args)=>fetch(...args),credentials:{get:options=>globalThis.navigator.credentials.get(options)}})):null;
  const pending = location.hash;
  // Callback fragment is always removed before a promise, fetch or Flutter load.
  if (pending) history.replaceState(null, '', location.pathname + location.search);
  let saved;
  if (pending) { try { saved = sessionStorage.getItem(KEY); sessionStorage.removeItem(KEY); } catch {} }
  const ready = (async () => {
    if (!pending) {
      let remembered=false;try{remembered=localStorage.getItem('otpanda-session-present')==='yes';}catch{}
      if(remembered){const verifier=random(),state=random(),attempt=generation;status='restoring';const challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));if(attempt!==generation)return;sessionStorage.setItem(KEY,JSON.stringify({verifier,state,created:Date.now()}));location.assign(API+'/auth/restore?'+new URLSearchParams({challenge,state,redirect_uri:REDIRECT}));}
      return;
    }
    if(pending==='#auth=logout-incomplete&state='){try{localStorage.removeItem('otpanda-session-present');}catch{}clear();status='logout-incomplete';return;}
    status = 'restoring';const attempt=generation;
    try {
      if (location.origin + location.pathname !== REDIRECT || location.search || pending.length > 8192 || !saved) throw Error();
      const values = new URLSearchParams(pending.slice(1));
      const state=values.get('state'),p=JSON.parse(saved),now=Date.now();
      if(!/^[A-Za-z0-9_-]{43}$/.test(state)||state!==p.state||!/^[A-Za-z0-9_-]{43}$/.test(p.verifier)||!Number.isSafeInteger(p.created)||now<p.created||now-p.created>((values.has('signup')||values.has('auth'))?900000:300000))throw Error();
      if([...values.keys()].sort().join(',')==='auth,state'){
        const value=values.get('auth');if(!['email-sent','email-invalid','code-invalid','restart','retry','existing-account','sign-in','legacy-account'].includes(value))throw Error();
        entryEmail=typeof p.email==='string'&&p.email.length<=254?p.email:'';
        if(['restart','retry','sign-in'].includes(value))try{localStorage.removeItem('otpanda-session-present');}catch{}
        status=value==='email-sent'?'email-code':value==='sign-in'?'sign-in-required':value;
        return;
      }
      if([...values.keys()].sort().join(',')==='protection,state'){
        const q=JSON.parse(values.get('protection'));if(Object.keys(q).sort().join(',')!=='expiresAt,pendingId,token'||!/^otpda_[A-Za-z0-9_-]{55}$/.test(q.token)||typeof q.pendingId!=='string'||q.pendingId.length>128||!Number.isSafeInteger(q.expiresAt)||q.expiresAt<=now||q.expiresAt>now+600000)throw Error();protectionPending={...q,saved:p};status='extra-verification';return;
      }
      if([...values.keys()].sort().join(',')==='google,state'){
        const g=JSON.parse(values.get('google'));if(Object.keys(g).sort().join(',')!=='email,expiresAt,kind,token'||!/^otpda_[A-Za-z0-9_-]{55}$/.test(g.token)||!['link','email'].includes(g.kind)||typeof g.email!=='string'||g.email.length>254||!Number.isSafeInteger(g.expiresAt)||g.expiresAt<=now||g.expiresAt>now+600000)throw Error();googlePending={...g,saved:p};entryEmail=g.email;status=g.kind==='email'?'google-email':'google-link';return;
      }
      if(['login,state','signup,state'].includes([...values.keys()].sort().join(','))){
        const registration=values.has('signup');
        const encoded=values.get(registration?'signup':'login');if(!/^[A-Za-z0-9_-]{1,6000}$/.test(encoded))throw Error();
        const c=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(atob(encoded.replaceAll('-','+').replaceAll('_','/')),v=>v.charCodeAt(0))));
        if(Object.keys(c).sort().join(',')!=='expiresAt,options,token'||!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||!Number.isSafeInteger(c.expiresAt))throw Error();
        if(c.expiresAt<=now||c.expiresAt>now+120000){clear();status='check-clock-or-restart';return;}
        const o=c.options;
        if(registration){
          if(!o||Object.keys(o).some(k=>!['rp','user','challenge','pubKeyCredParams','timeout','attestation','excludeCredentials','authenticatorSelection','extensions','hints'].includes(k))||o.rp?.id!=='otpanda.github.io'||o.rp.name!=='OTPanda'||typeof o.user?.id!=='string'||!/^[A-Za-z0-9_-]{1,128}$/.test(o.user.id)||typeof o.user.name!=='string'||o.user.name.length>254||typeof o.user.displayName!=='string'||o.user.displayName.length>254||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||o.timeout!==120000||o.attestation!=='none'||o.authenticatorSelection?.residentKey!=='required'||o.authenticatorSelection?.userVerification!=='required'||!Array.isArray(o.pubKeyCredParams)||o.pubKeyCredParams.length!==2||o.pubKeyCredParams.some(v=>v.type!=='public-key'||![-7,-257].includes(v.alg))||!Array.isArray(o.excludeCredentials)||o.excludeCredentials.length||(o.extensions&&Object.keys(o.extensions).some(k=>k!=='credProps'||o.extensions[k]!==true))||(o.hints&&(!Array.isArray(o.hints)||o.hints.length)))throw Error();
        }else{
const o=c.options;if(!o||Object.keys(o).some(k=>!['rpId','challenge','timeout','userVerification','allowCredentials','extensions'].includes(k))||o.rpId!=='otpanda.github.io'||o.userVerification!=='required'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||o.timeout!==120000||(o.allowCredentials!==undefined&&(!Array.isArray(o.allowCredentials)||o.allowCredentials.length))||(o.extensions!==undefined&&Object.keys(o.extensions).length))throw Error();
        }
        loginPending={ceremony:c,saved:p,registration};status=registration?'signup-ready':'passkey-ready';
        // A valid login callback can prompt immediately at the app RP. Keep a
        // deliberate retry only if the browser requires a new user gesture.
        if(!registration&&globalThis.navigator?.credentials?.get){Promise.resolve().then(()=>globalThis.OTPandaSession.passkey(true));}return;
      }
      if (!['code,state','code,enrollment,state'].includes([...values.keys()].sort().join(','))) throw Error();
      const code=values.get('code');if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(code))throw Error();
      const response = await fetch(API+'/auth/exchange', {method:'POST', credentials:'omit', cache:'no-store', redirect:'error', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code,verifier:p.verifier,redirect_uri:REDIRECT})});
      if (!response.ok) throw Error();
      const text = await readBounded(response,2048);
      const result = JSON.parse(text);
      if (Object.keys(result).sort().join(',') !== 'access,accessExpiresAt' || !/^otpda_[A-Za-z0-9_-]{55}$/.test(result.access) || !Number.isSafeInteger(result.accessExpiresAt) || result.accessExpiresAt <= Date.now() || result.accessExpiresAt > Date.now()+300000) throw Error();
      if(attempt!==generation)return;
      try{localStorage.setItem('otpanda-session-present','yes');}catch{}access = result.access; expires=result.accessExpiresAt;status='restored';const grant=values.get('enrollment');if(grant&&/^otpda_[A-Za-z0-9_-]{55}$/.test(grant))enrollment=grant;
    } catch { if(attempt===generation){try{localStorage.removeItem('otpanda-session-present');}catch{}clear();status='sign-in-required';} }
  })();
  const assertion=async c=>{
    const o=c.options,decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
    if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||o?.rpId!=='otpanda.github.io'||o.userVerification!=='required'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||!Array.isArray(o.allowCredentials)||o.allowCredentials.length>50||!Number.isSafeInteger(c.expiresAt)||c.expiresAt<=Date.now()||c.expiresAt>Date.now()+120000)throw Error('Invalid passkey verification');
    const credential=await navigator.credentials.get({publicKey:{rpId:'otpanda.github.io',challenge:decode(o.challenge),userVerification:'required',timeout:Math.min(120000,c.expiresAt-Date.now()),allowCredentials:o.allowCredentials.map(v=>({type:'public-key',id:decode(v.id)}))}});if(!credential)throw Error('Passkey verification cancelled');
    return{id:credential.id,rawId:encode(new Uint8Array(credential.rawId)),type:credential.type,clientExtensionResults:credential.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(credential.response.clientDataJSON)),authenticatorData:encode(new Uint8Array(credential.response.authenticatorData)),signature:encode(new Uint8Array(credential.response.signature)),userHandle:credential.response.userHandle?encode(new Uint8Array(credential.response.userHandle)):null}};
  };
  Object.defineProperty(globalThis,'OTPandaSession',{value:Object.freeze({
    ready,
    assignmentPrepare:async target=>{if(!assignment)throw Error('Assignment unavailable');return JSON.stringify(await assignment.prepare(JSON.parse(target)));},
    assignmentConfirm:async()=>{if(!assignment)throw Error('Assignment unavailable');return assignment.confirm();},
    assignmentReconcile:async()=>{if(!assignment)throw Error('Assignment unavailable');return assignment.reconcile();},
    assignmentState:()=>assignment?.state??'unsupported',
    assignmentDismiss:()=>assignment?.dismiss(),
    status:()=>status,
    email:()=>entryEmail,
    googleStart:async remember=>globalThis.OTPandaSession.start('google',remember),
    signupEmail:async(email,proof='')=>{
      if(location.origin+location.pathname!==REDIRECT||location.search||typeof email!=='string'||email.length>254||typeof proof!=='string'||(proof&&!/^otpda_[A-Za-z0-9_-]{55}$/.test(proof)&&! /^[A-HJ-NP-Z2-9]{8}$/i.test(proof.replaceAll(' ','').replaceAll('-',''))))throw Error('Valid signup details required');
      clear();const attempt=generation,verifier=random(),state=random(),challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));if(attempt!==generation)return;
      sessionStorage.setItem(KEY,JSON.stringify({verifier,state,created:Date.now(),email}));
      const u=new URL(API+'/auth/signup/app');u.search=new URLSearchParams({challenge,state,redirect_uri:REDIRECT});u.hash=new URLSearchParams({action:proof?'begin':'email',email,...(proof?{email_token:proof}:{})});location.assign(u.href);
    },
    access:()=>{if(access!==undefined&&Date.now()>=expires){clear();status='sign-in-required';}return access;},
    clear:()=>{try{localStorage.removeItem('otpanda-session-present');}catch{}clear();status='idle';try{sessionStorage.removeItem(KEY);}catch{}},
    logout:()=>{try{localStorage.removeItem('otpanda-session-present');}catch{}clear();status='idle';try{sessionStorage.removeItem(KEY);}catch{}location.assign(API+'/auth/device/logout');},
    read:async path=>{
      if(!['/v1/manage/account','/v1/manage/session','/v1/manage/entries','/v1/manage/active-codes','/v1/manage/sources','/v1/manage/unassigned'].includes(path))throw Error('Read path required');
      const attempt=generation,token=Date.now()<expires?access:undefined;if(!token){if(access!==undefined){clear();status='sign-in-required';}return {status:401,body:'{}'};}
      const r=await fetch(API+path,{method:'GET',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token}});const body=await readBounded(r,524288);
      if(attempt!==generation)return {status:401,body:'{}'};
      if(r.status===401){clear();status='sign-in-required';}
      return {status:r.status,body};
    },
    organize:async(method,body='')=>{
      if(!['GET','PUT'].includes(method)||typeof body!=='string'||new TextEncoder().encode(body).byteLength>131072||(method==='GET'&&body))throw Error('Organization request required');
      const attempt=generation,token=Date.now()<expires?access:undefined;
      if(!token)return {status:401,body:'{}'};
      const r=await fetch(API+'/v1/manage/organization',{method,credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,...(method==='PUT'?{'Content-Type':'application/json'}:{})},...(method==='PUT'?{body}:{})});
      const text=await readBounded(r,524288);if(attempt!==generation)return {status:401,body:'{}'};
      if(r.status===401){clear();status='sign-in-required';}return {status:r.status,body:text};
    },
    copied:async(entryId,createdAt)=>{
      if(typeof entryId!=='string'||!entryId||entryId.length>256||!Number.isSafeInteger(createdAt))throw Error('Copy receipt required');
      const attempt=generation,token=Date.now()<expires?access:undefined;if(!token)return {status:401,body:'{}'};
      const receiptId=random();
      const r=await fetch(API+'/v1/manage/organization-copy',{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({entryId,receiptId,createdAt})});
      const body=await readBounded(r,4096);if(attempt!==generation)return {status:401,body:'{}'};
      if(r.status===401){clear();status='sign-in-required';}return {status:r.status,body};
    },
    pendingLabel:()=>protectionPending?.pendingId.slice(0,6).toUpperCase()??'',
    protectionContinue:async action=>{
      const p=protectionPending,attempt=generation;if(!p||p.expiresAt<=Date.now()||!['passkey','check'].includes(action))throw Error('Start sign-in again.');
      const post=async(path,value)=>{const r=await fetch(API+'/auth/google/protection/'+path,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-OTPanda-Pending':p.token},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,16384));if(!r.ok||attempt!==generation)throw Error('Verification expired. Start sign-in again.');return v;};
      if(action==='passkey'){const c=await post('begin',{}),response=await assertion(c);if(attempt!==generation)return;await post('verify',{token:c.token,response});}
      const value=await post('status',{});if(value.status==='waiting')return 'waiting';if(value.status!=='approved')throw Error('Verification expired.');if(attempt!==generation)return 'cancelled';sessionStorage.setItem(KEY,JSON.stringify({...p.saved,created:Date.now()}));protectionPending=undefined;location.assign(API+'/auth/google/protection/complete#'+new URLSearchParams({token:p.token}));return 'approved';
    },
    security:async(action,enabled=false,pendingId='')=>{
      const attempt=generation,token=Date.now()<expires?access:undefined;if(!token||!['status','toggle','approve','deny','request-change','approve-change','consume-change'].includes(action))throw Error('Sign in again.');
      const post=async(path,value)=>{const r=await fetch(API+'/v1/manage/security/'+path,{method:path==='status'?'GET':'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,...(path==='status'?{}:{'Content-Type':'application/json'})},...(path==='status'?{}:{body:JSON.stringify(value)})});const v=JSON.parse(await readBounded(r,16384));if(!r.ok||attempt!==generation)throw Error('Security update did not finish. Try again.');return v;};
      if(action==='status')return JSON.stringify(await post('status'));
      if(action==='request-change')return JSON.stringify(await post(action,{enabled,warningAccepted:true}));
      if(action==='approve-change'||action==='consume-change')return JSON.stringify(await post(action,{changeId:pendingId}));
      if(action==='approve'||action==='deny'){await post(action,{pendingId});return '{}';}
      const value={enabled,warningAccepted:true},c=await post('begin',value),response=await assertion(c);if(attempt!==generation)return '{}';await post('finish',{...value,token:c.token,response});return '{}';
    },
    googleContinue:async(action,proof='')=>{
      const g=googlePending,attempt=generation;if(!g||g.expiresAt<=Date.now()||!['email','verify-email','link'].includes(action))throw Error('Start Google sign-in again.');
      const post=async(path,value)=>{const r=await fetch(API+'/auth/google/continue/'+path,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-OTPanda-Continuation':g.token},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,16384));if(!r.ok||attempt!==generation)throw Error('Could not verify this account. Start Google sign-in again.');return v;};
      if(action==='email'){await post('email',{});return;}
      let value={ceremony:null,response:null,emailProof:proof};
      if(action==='link'){
        const c=await post('begin',{}),o=c.options;if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||o?.rpId!=='otpanda.github.io'||o.userVerification!=='required'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||!Array.isArray(o.allowCredentials)||o.allowCredentials.length>20)throw Error('Invalid sign-in request');
        const decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0)),credential=await navigator.credentials.get({publicKey:{rpId:'otpanda.github.io',challenge:decode(o.challenge),userVerification:'required',timeout:120000,allowCredentials:o.allowCredentials.map(v=>({type:'public-key',id:decode(v.id)}))}});if(!credential||attempt!==generation)throw Error('Account verification cancelled');
        value={ceremony:c.token,emailProof:null,response:{id:credential.id,rawId:encode(new Uint8Array(credential.rawId)),type:credential.type,clientExtensionResults:credential.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(credential.response.clientDataJSON)),authenticatorData:encode(new Uint8Array(credential.response.authenticatorData)),signature:encode(new Uint8Array(credential.response.signature)),userHandle:credential.response.userHandle?encode(new Uint8Array(credential.response.userHandle)):null}}};
      }
      await post('verify',value);if(attempt!==generation)return;sessionStorage.setItem(KEY,JSON.stringify({...g.saved,created:Date.now()}));googlePending=undefined;location.assign(API+'/auth/google/continue/complete#'+new URLSearchParams({token:g.token}));
    },
    addPasskey:async()=>{
      const attempt=generation,token=Date.now()<expires?access:undefined;if(!token)throw Error('Sign in again.');
      const post=async(step,value,grant)=>{const r=await fetch(API+'/v1/manage/passkey/add/'+step,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',...(grant?{'X-OTPanda-Enrollment':grant}:{})},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,24576));if(!r.ok||attempt!==generation)throw Error('Passkey setup could not finish. Start again.');return v;};
      const verification=await post('verify-begin',{}),response=await assertion(verification);if(attempt!==generation)throw Error('Cancelled');const grant=await post('verify-finish',{token:verification.token,response});if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(grant.token)||!Number.isSafeInteger(grant.expiresAt)||grant.expiresAt<=Date.now()||grant.expiresAt>Date.now()+120000)throw Error('Invalid authorization');
      const c=await post('register-begin',{},grant.token),o=c.options,decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
      if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||o?.rp?.id!=='otpanda.github.io'||o.rp.name!=='OTPanda'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||!Number.isSafeInteger(c.expiresAt)||c.expiresAt<=Date.now()||c.expiresAt>Date.now()+120000||o.authenticatorSelection?.userVerification!=='required'||!Array.isArray(o.excludeCredentials)||o.excludeCredentials.length>10||o.excludeCredentials.some(v=>v.type!=='public-key'||typeof v.id!=='string'||!/^[A-Za-z0-9_-]{1,1400}$/.test(v.id)))throw Error('Invalid passkey setup');
      const credential=await navigator.credentials.create({publicKey:{rp:o.rp,user:{...o.user,id:decode(o.user.id)},challenge:decode(o.challenge),pubKeyCredParams:[{type:'public-key',alg:-7},{type:'public-key',alg:-257}],timeout:Math.min(120000,c.expiresAt-Date.now()),attestation:'none',authenticatorSelection:{residentKey:'required',userVerification:'required'},excludeCredentials:o.excludeCredentials.map(v=>({type:'public-key',id:decode(v.id)}))}});if(attempt!==generation||!credential||credential.type!=='public-key')throw Error('Cancelled');
      await post('register-finish',{token:c.token,response:{id:credential.id,rawId:encode(new Uint8Array(credential.rawId)),type:credential.type,clientExtensionResults:credential.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(credential.response.clientDataJSON)),attestationObject:encode(new Uint8Array(credential.response.attestationObject)),transports:credential.response.getTransports?.()??[]}}},grant.token);
    },
    firstPasskeyAvailable:()=>Boolean(enrollment&&Date.now()<expires),
    firstPasskey:async()=>{
      const attempt=generation,grant=enrollment,token=Date.now()<expires?access:undefined;if(!grant||!token)throw Error('Sign in with Google again to add your first passkey.');
      const post=async(path,value)=>{const r=await fetch(API+'/v1/manage/first-passkey/'+path,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','X-OTPanda-Enrollment':grant},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,16384));if(!r.ok||attempt!==generation)throw Error('Sign in with Google again to add your first passkey.');return v;};
      const c=await post('begin',{}),o=c.options,decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
      if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||o?.rp?.id!=='otpanda.github.io'||o.rp.name!=='OTPanda'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||!Number.isSafeInteger(c.expiresAt)||c.expiresAt<=Date.now()||c.expiresAt>Date.now()+120000||o.authenticatorSelection?.userVerification!=='required'||!Array.isArray(o.excludeCredentials)||o.excludeCredentials.length)throw Error('Invalid passkey setup');
      const credential=await navigator.credentials.create({publicKey:{rp:o.rp,user:{...o.user,id:decode(o.user.id)},challenge:decode(o.challenge),pubKeyCredParams:[{type:'public-key',alg:-7},{type:'public-key',alg:-257}],timeout:Math.min(120000,c.expiresAt-Date.now()),attestation:'none',authenticatorSelection:{residentKey:'required',userVerification:'required'},excludeCredentials:[]}});
      if(attempt!==generation||!credential||credential.type!=='public-key')throw Error('Passkey setup cancelled');
      const response={id:credential.id,rawId:encode(new Uint8Array(credential.rawId)),type:credential.type,clientExtensionResults:credential.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(credential.response.clientDataJSON)),attestationObject:encode(new Uint8Array(credential.response.attestationObject)),transports:credential.response.getTransports?.()??[]}};
      enrollment=undefined;await post('finish',{token:c.token,response});
    },
    passkey:async(automatic=false)=>{
      const pending=loginPending;if(!pending||!['passkey-ready','signup-ready'].includes(status))throw Error('Start sign-in again');
      loginPending=undefined;const attempt=++generation;let credentialReceived=false;status='authenticating';
      try{
        if(pending.ceremony.expiresAt<=Date.now()||Date.now()-pending.saved.created>(pending.registration?900000:300000))throw Error();
        const decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
        const o=pending.ceremony.options,c=pending.registration?await navigator.credentials.create({publicKey:{rp:o.rp,user:{...o.user,id:decode(o.user.id)},challenge:decode(o.challenge),pubKeyCredParams:o.pubKeyCredParams,timeout:Math.min(120000,pending.ceremony.expiresAt-Date.now()),attestation:'none',authenticatorSelection:{residentKey:'required',userVerification:'required'},excludeCredentials:[],extensions:{credProps:true}}}):await navigator.credentials.get({publicKey:{rpId:'otpanda.github.io',challenge:decode(o.challenge),timeout:Math.min(120000,pending.ceremony.expiresAt-Date.now()),userVerification:'required'}});
        if(attempt!==generation)return;
        if(!c||c.type!=='public-key')throw Error();credentialReceived=true;
        const response={id:c.id,rawId:encode(new Uint8Array(c.rawId)),type:c.type,clientExtensionResults:c.getClientExtensionResults(),response:pending.registration?{clientDataJSON:encode(new Uint8Array(c.response.clientDataJSON)),attestationObject:encode(new Uint8Array(c.response.attestationObject)),transports:typeof c.response.getTransports==='function'?c.response.getTransports():[]}:{clientDataJSON:encode(new Uint8Array(c.response.clientDataJSON)),authenticatorData:encode(new Uint8Array(c.response.authenticatorData)),signature:encode(new Uint8Array(c.response.signature)),userHandle:c.response.userHandle?encode(new Uint8Array(c.response.userHandle)):null}};
        const r=await fetch(API+(pending.registration?'/auth/signup/verify':'/auth/login/verify'),{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:pending.ceremony.token,response})});if(!r.ok)throw Error();const text=await readBounded(r,2048);const result=JSON.parse(text);
        if(Object.keys(result).sort().join(',')!=='expiresAt,handoff'||!/^otpda_[A-Za-z0-9_-]{55}$/.test(result.handoff)||!Number.isSafeInteger(result.expiresAt)||result.expiresAt<=Date.now()||result.expiresAt>Date.now()+60000)throw Error();
        if(attempt!==generation)return;
        sessionStorage.setItem(KEY,JSON.stringify({...pending.saved,created:Date.now()}));status='completing';location.assign(API+'/auth/login/complete#'+new URLSearchParams({handoff:result.handoff}));
      }catch{if(attempt===generation){if(automatic&&!credentialReceived&&!pending.registration&&pending.ceremony.expiresAt>Date.now()){loginPending=pending;status='passkey-ready';}else{clear();status=pending.registration?'signup-retry-required':'sign-in-required';}}}
    },
    start:async(mode='restore',remember=true)=>{
      if(location.origin+location.pathname!==REDIRECT||location.search)throw Error('Canonical app URL required');
      if(!['restore','login','signup','google'].includes(mode))throw Error('Known session flow required');
      clear();const attempt=generation,verifier=random(),state=random(),challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
      if(attempt!==generation)return;
      sessionStorage.setItem(KEY,JSON.stringify({verifier,state,created:Date.now()}));
      const url=new URL(API+(mode==='google'?'/auth/google/start':mode==='signup'?'/auth/signup/start':mode==='login'?'/auth/login/start':'/auth/restore'));url.search=new URLSearchParams({challenge,state,redirect_uri:REDIRECT,...(mode==='google'?{remember:remember?'yes':'no'}:{})});location.assign(url.href);
    },
  }),writable:false,configurable:false});
})();
