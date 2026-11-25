/* Runs before Flutter or any other app script. Access stays in this closure. */
(() => {
  'use strict';
  const API = 'https://otpanda-api.abrahammurciano.workers.dev';
  const REDIRECT = 'https://otpanda.github.io/app/';
  const GMAIL_SCOPES = ['https://www.googleapis.com/auth/gmail.readonly', 'https://www.googleapis.com/auth/gmail.labels', 'https://www.googleapis.com/auth/gmail.settings.basic'];
  const sameScopes = v => { if (typeof v !== 'string') return false; const p = v.split(' '); return p.length === GMAIL_SCOPES.length && new Set(p).size === p.length && GMAIL_SCOPES.every(x => p.includes(x)); };
  const KEY = 'otpanda.restore.tab.v1';
  const READ_RESTORE_KEY = 'otpanda.read.restore.v1';
  // Static identity (email, picture) cached for this sign-in only. It dies with the
  // session-present flag and is never read without matching owner and session ids.
  const PROFILE_KEY = 'otpanda-profile-v1';
  const forgetProfile=()=>{try{localStorage.removeItem(PROFILE_KEY);}catch{}};
  // Another tab ended or replaced the sign-in: this tab stops using and showing
  // the cached identity until it starts a sign-in itself.
  let profileRevoked=false;const revokeListeners=new Set();
  const revokeProfile=()=>{if(profileRevoked)return;profileRevoked=true;forgetProfile();for(const f of [...revokeListeners]){try{f();}catch{}}};
  try{globalThis.addEventListener?.('storage',e=>{if(e.key===null||(e.key==='otpanda-session-present'&&e.newValue!=='yes')||(e.key===PROFILE_KEY&&e.newValue===null))revokeProfile();});}catch{}
  const resetReadRestore=()=>{try{sessionStorage.removeItem(READ_RESTORE_KEY);}catch{}};
  const VIEW_KEY = 'otpanda.view.tab.v1';
  // Signed-in "Connect Google": one tab-scoped marker holding only an opaque
  // state and the route to come back to. No token, key or bearer is stored.
  const LINK_KEY = 'otpanda.google-link.tab.v1';
  const LINK_NOTICES = ['connected', 'restart', 'mismatch', 'cancelled'];
  const validView = v => Number.isInteger(v) && v >= 0 && v <= 5;
  let view = 0;
  try { const stored=sessionStorage.getItem(VIEW_KEY);if(stored!==null&&/^[0-5]$/.test(stored))view=Number(stored); } catch {}
  const forgetView=()=>{view=0;try{sessionStorage.removeItem(VIEW_KEY);}catch{}};
  let signingKey, renewal, renewing, restoring, serverOffset=0, renewalRetryAt=0;
  const serverNow=()=>Date.now()+serverOffset;
  let linkResult, access, expires = 0, status = 'idle', generation = 0, loginPending, entryEmail='',enrollment,googlePending,protectionPending;
  const encode = bytes => btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
  const random = () => encode(crypto.getRandomValues(new Uint8Array(32)));
  let realtime;
  const clear = () => { realtime?.suspend();assignment?.clear();generation++; renewalRetryAt=0;signingKey=undefined;renewal=undefined;renewing=undefined;restoring=undefined;access = undefined; expires = 0; loginPending=undefined;enrollment=undefined;googlePending=undefined;protectionPending=undefined; };
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
  const assignment=typeof globalThis.OTPandaAssignmentController==='function'&&typeof globalThis.OTPandaAssignmentTransport==='function'?new globalThis.OTPandaAssignmentController(globalThis.OTPandaAssignmentTransport({access:()=>serverNow()<expires?access:undefined,generation:()=>generation,fetchImpl:(...args)=>fetch(...args),credentials:{get:options=>globalThis.navigator.credentials.get(options)}})):null;
  // Route identifiers contain no record ids, query, proof or free-form return URL.
  const ROUTES=['codes','sources','unassigned','entries','settings','settings/account-security','settings/devices','settings/organization','settings/about','settings/account-security/passkeys','recovery','recovery/start','recovery/finish','demo'];
  const ROUTE_KEY='otpanda.route.tab.v1',validRoute=r=>ROUTES.includes(r);
  let route;const routeListeners=new Set();
  const persistentRoute=r=>validRoute(r)&&!r.startsWith('recovery')&&r!=='demo';
  try{const r=sessionStorage.getItem(ROUTE_KEY);if(persistentRoute(r))route=r;}catch{}
  const routeHash=location.hash.startsWith('#/');
  if(routeHash)route=validRoute(location.hash.slice(2))?location.hash.slice(2):'codes';
  const saveRoute=()=>{try{if(persistentRoute(route))sessionStorage.setItem(ROUTE_KEY,route);else sessionStorage.removeItem(ROUTE_KEY);}catch{}};
  const routeChanged=()=>{saveRoute();for(const f of routeListeners)f();};
  const showRoute=(r,replace=false)=>{if(!validRoute(r))throw Error('Known route required');route=r;const hash='#/'+r;if(location.hash!==hash)history[replace?'replaceState':'pushState'](null,'',location.pathname+location.search+hash);routeChanged();};
  const receiveRoute=()=>{if(!location.hash.startsWith('#/'))return;const r=location.hash.slice(2),next=validRoute(r)?r:'codes';if(route!==next||location.hash!=='#/'+next){const wasPublic=route?.startsWith('recovery')||route==='demo';showRoute(next,true);if(wasPublic&&persistentRoute(next)&&status==='idle'){let hint=false;try{hint=localStorage.getItem('otpanda-session-present')==='yes';}catch{}if(hint)Promise.resolve().then(()=>globalThis.OTPandaSession.start('restore'));}}};
  globalThis.addEventListener?.('popstate',receiveRoute);globalThis.addEventListener?.('hashchange',receiveRoute);
  Object.defineProperty(globalThis,'OTPandaNavigation',{value:Object.freeze({current:()=>route??ROUTES[Math.min(view,4)],go:r=>{const wasPublic=route?.startsWith('recovery')||route==='demo';showRoute(r);if(wasPublic&&persistentRoute(r)&&status==='idle'){let hint=false;try{hint=localStorage.getItem('otpanda-session-present')==='yes';}catch{}if(hint)Promise.resolve().then(()=>globalThis.OTPandaSession.start('restore'));}},listen:f=>routeListeners.add(f),unlisten:f=>routeListeners.delete(f)}),writable:false,configurable:false});
  if(routeHash)saveRoute();
  const pending = routeHash?'':location.hash;
  // Callback fragment is always removed before a promise, fetch or Flutter load.
  if (pending) history.replaceState(null, '', location.pathname + location.search);
  let saved;
  if (pending) { try { saved = sessionStorage.getItem(KEY); sessionStorage.removeItem(KEY); } catch {} }
  // First-party restore, optionally carrying a one-time link result to show once.
  const startRestore=async notice=>{
    const verifier=random(),state=random(),attempt=generation;status='restoring';
    const challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
    if(attempt!==generation)return;
    sessionStorage.setItem(KEY,JSON.stringify({verifier,state,...(route?{route}:{}),created:Date.now(),...(LINK_NOTICES.includes(notice)?{linkNotice:notice}:{})}));
    location.assign(API+'/auth/restore?'+new URLSearchParams({challenge,state,redirect_uri:REDIRECT}));
  };
  // A link return counts only with a live marker whose state matches. Anything
  // else returns false and goes through the ordinary (strict) parsing.
  const linkReturn=async (pending,hasOrdinaryRecord)=>{
    let m;try{m=JSON.parse(sessionStorage.getItem(LINK_KEY)??'null');}catch{return false;}
    const now=Date.now();
    if(!m||typeof m!=='object'||!/^[A-Za-z0-9_-]{43}$/.test(m.state)||!Number.isSafeInteger(m.created)||now<m.created||!validRoute(m.route))return false;
    if(location.origin+location.pathname!==REDIRECT||location.search||pending.length>8192)return false;
    const values=new URLSearchParams(pending.slice(1)),keys=[...values.keys()].sort().join(','),state=values.get('state');
    const consume=()=>{try{sessionStorage.removeItem(LINK_KEY);}catch{}route=m.route;saveRoute();};
    // A link that ended, or came back too late, only restores the session and
    // says so. It never accepts a token, state or sign-in from the hash.
    const ended=async(notice='restart')=>{consume();await startRestore(notice);return true;};
    // Success needs a fresh marker (10 minutes) and the exact state.
    const fresh=now-m.created<=600000;
    if(keys==='google,state'&&state===m.state){
      if(!fresh)return ended();
      // A matching state that is not a valid pending link ends the attempt and
      // restores; it must not fall through to the sign-in parser.
      let g;try{g=JSON.parse(values.get('google'));}catch{return ended();}
      if(!g||typeof g!=='object'||Object.keys(g).sort().join(',')!=='email,expiresAt,kind,token'||g.kind!=='link-only'||!/^otpda_[A-Za-z0-9_-]{55}$/.test(g.token)||typeof g.email!=='string'||g.email.length>254||!Number.isSafeInteger(g.expiresAt)||g.expiresAt<=now||g.expiresAt>now+600000)return ended();
      consume();googlePending={...g,linkOnly:true};entryEmail=g.email;status='google-link-only';return true;
    }
    if(keys==='link,state')return ended(['restart','mismatch'].includes(values.get('link'))?values.get('link'):'restart');
    // A link-shaped return with a live marker never reaches the sign-in parser,
    // whatever its state: restore only, hint kept, unknown reason means restart.
    // The ordinary failure shape, but only when no ordinary sign-in is in
    // flight (it saves its own record first) and a link marker exists.
    if(keys==='auth,state'&&['restart','retry'].includes(values.get('auth'))&&!hasOrdinaryRecord)return ended();
    return false;
  };
  const ready = (async () => {
    if (!pending) {
      // This hint describes an active session, not remembered-device recognition.
      let sessionPresent=false;try{sessionPresent=localStorage.getItem('otpanda-session-present')==='yes';}catch{}
      if(sessionPresent&&!route?.startsWith('recovery')&&route!=='demo'){const verifier=random(),state=random(),attempt=generation;status='restoring';const challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));if(attempt!==generation)return;sessionStorage.setItem(KEY,JSON.stringify({verifier,state,...(route?{route}:{}),created:Date.now()}));location.assign(API+'/auth/restore?'+new URLSearchParams({challenge,state,redirect_uri:REDIRECT}));}
      return;
    }
    if(pending==='#auth=logout-incomplete&state='){forgetProfile();try{localStorage.removeItem('otpanda-session-present');}catch{}clear();status='logout-incomplete';return;}
    if(/^#(google|link|auth)=/.test(pending)&&await linkReturn(pending,Boolean(saved)))return;
    status = 'restoring';const attempt=generation;
    try {
      if (location.origin + location.pathname !== REDIRECT || location.search || pending.length > 8192 || !saved) throw Error();
      const values = new URLSearchParams(pending.slice(1));
      const state=values.get('state'),p=JSON.parse(saved),now=Date.now();
      if(!/^[A-Za-z0-9_-]{43}$/.test(state)||state!==p.state||!/^[A-Za-z0-9_-]{43}$/.test(p.verifier)||!Number.isSafeInteger(p.created)||now<p.created||now-p.created>((values.has('signup')||values.has('auth'))?900000:300000))throw Error();
      if(p.route!==undefined&&!validRoute(p.route))throw Error();
      if(p.linkNotice!==undefined&&!LINK_NOTICES.includes(p.linkNotice))throw Error();
      if(p.route!==undefined){route=p.route;saveRoute();}
      if([...values.keys()].sort().join(',')==='auth,state'){
        const value=values.get('auth');if(!['email-sent','email-invalid','code-invalid','restart','retry','existing-account','sign-in','legacy-account'].includes(value))throw Error();
        entryEmail=typeof p.email==='string'&&p.email.length<=254?p.email:'';
        if(value==='retry'&&!p.restoreRetried&&typeof globalThis.setTimeout==='function'){
          status='restoring';view=p.view??view;
          await new Promise(resolve=>setTimeout(resolve,1000+Math.floor(Math.random()*1000)));
          if(attempt!==generation)return;
          const verifier=random(),state=random(),challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
          if(attempt!==generation)return;
          sessionStorage.setItem(KEY,JSON.stringify({verifier,state,...(route?{route}:{}),created:Date.now(),view,restoreRetried:true,...(p.linkNotice?{linkNotice:p.linkNotice}:{})}));
          location.assign(API+'/auth/restore?'+new URLSearchParams({challenge,state,redirect_uri:REDIRECT}));return;
        }
        if(['restart','retry','sign-in'].includes(value)){forgetProfile();try{localStorage.removeItem('otpanda-session-present');}catch{}}
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
      if(p.view !== undefined && !validView(p.view))throw Error();
      view=p.view??view;
      const code=values.get('code');if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(code))throw Error();
      let candidateKey, publicKey;
      try {
        const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);
        publicKey=encode(new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey)));
        candidateKey=pair.privateKey;
      } catch {} // Unsupported crypto uses the existing first-party restore path.
      if(attempt!==generation)return;
      const response = await fetch(API+'/auth/exchange', {method:'POST', credentials:'omit', cache:'no-store', redirect:'error', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code,verifier:p.verifier,redirect_uri:REDIRECT,...(publicKey?{renewal_key:publicKey}:{})})});
      if (!response.ok) throw Error();
      const result = JSON.parse(await readBounded(response,4096));
      const nextOffset=validateAccess(result);
      if(attempt!==generation)return;
      try{localStorage.setItem('otpanda-session-present','yes');}catch{}
      serverOffset=nextOffset;access=result.access;expires=result.accessExpiresAt;status='restored';realtime?.nudge();if(p.linkNotice)linkResult=p.linkNotice;
      if(candidateKey&&validRenewal(result.renewal,result.access)&&result.renewal.firstPartyExpiresAt!==undefined) {signingKey=candidateKey;renewal=result.renewal;}
      const grant=values.get('enrollment');if(grant&&/^otpda_[A-Za-z0-9_-]{55}$/.test(grant))enrollment=grant;
    } catch { if(attempt===generation){forgetProfile();try{localStorage.removeItem('otpanda-session-present');}catch{}clear();status='sign-in-required';} }
  })();
  function validateAccess(result,tabKey=false) {
    const clock=result?.renewal?.serverTime;
    if(clock!==undefined&&(!Number.isSafeInteger(clock)||clock<0))throw Error('Invalid server clock');
    const now=clock??serverNow();
    if(!result||!['access,accessExpiresAt','access,accessExpiresAt,renewal'].includes(Object.keys(result).sort().join(','))||!/^otpda_[A-Za-z0-9_-]{55}$/.test(result.access)||!Number.isSafeInteger(result.accessExpiresAt)||result.accessExpiresAt<=now||result.accessExpiresAt>now+300000)throw Error('Invalid session response');
    if(result.renewal!==undefined&&(result.accessExpiresAt-clock!==300000||!validRenewal(result.renewal,result.access,now,tabKey)))throw Error('Invalid renewal response');
    return clock===undefined?serverOffset:clock-Date.now();
  }
  function validRenewal(value,token,now=serverNow(),tabKey=false) {
    return value&&Number.isSafeInteger(value.serverTime)&&value.serverTime>=0&&['firstPartyExpiresAt,handleId,lineageId,serverTime','handleId,lineageId,serverTime'].includes(Object.keys(value).sort().join(','))&&/^[A-Za-z0-9_-]{8,64}$/.test(value.lineageId)&&/^[A-Za-z0-9_-]{8,64}$/.test(value.handleId)&&token.slice(6,18)===value.handleId&&(value.firstPartyExpiresAt===undefined||(Number.isSafeInteger(value.firstPartyExpiresAt)&&(tabKey?value.firstPartyExpiresAt>0:value.firstPartyExpiresAt>now)&&value.firstPartyExpiresAt<=now+30*86400000));
  }
  async function restoreAfterUnauthorized() {
    clear();status='session-paused';
    // Persist only a cooldown timestamp across the first-party redirect, never access.
    try {
      const previous=Number(sessionStorage.getItem(READ_RESTORE_KEY));
      if(Number.isSafeInteger(previous)&&previous>0&&Date.now()-previous<60000){status='sign-in-required';return;}
      sessionStorage.setItem(READ_RESTORE_KEY,String(Date.now()));
    } catch { status='sign-in-required';return; } // Without a durable guard, do not risk a redirect loop.
    await restoreSession();
  }
  async function restoreSession() {
    if(restoring)return restoring;
    if(Date.now()<renewalRetryAt)return false;
    const attempt=generation;
    status='restoring';
    restoring=(async()=>{
      const verifier=random(),state=random(),challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
      if(attempt!==generation)return false;
      const navigate=async()=>{
        // A short public lease spaces tabs across the cookie rotation grace window.
        // It carries no token, account id, key or selected view.
        const leaseKey='otpanda.restore.lease.v1',owner=random();
        if(typeof globalThis.setTimeout==='function'){
          let until=0;try{const item=JSON.parse(localStorage.getItem(leaseKey));if(item&&Number.isSafeInteger(item.until)&&item.until>Date.now()&&item.until<Date.now()+15000)until=item.until;}catch{}
          if(until)await new Promise(resolve=>setTimeout(resolve,until-Date.now()+Math.floor(Math.random()*300)));
        }
        if(attempt!==generation)return false;
        try{localStorage.setItem(leaseKey,JSON.stringify({owner,until:Date.now()+3000}));}catch{}
        sessionStorage.setItem(KEY,JSON.stringify({verifier,state,...(route?{route}:{}),created:Date.now(),view}));
        location.assign(API+'/auth/restore?'+new URLSearchParams({challenge,state,redirect_uri:REDIRECT}));
        if(typeof globalThis.setTimeout==='function')setTimeout(()=>{if(attempt===generation&&status==='restoring'){restoring=undefined;renewalRetryAt=Date.now()+10000;status=serverNow()<expires?'restored':access?'session-paused':'sign-in-required';}},8000);
        return false;
      };
      return globalThis.navigator?.locks?.request?await navigator.locks.request('otpanda-firstparty-restore',navigate):await navigate();
    })().catch(()=>{if(attempt===generation){status='session-paused';restoring=undefined;}return false;});
    return restoring;
  }
  async function boundedRead(url,options,limit){
    const abort=new AbortController();let timer;
    const pending=(async()=>{const response=await fetch(url,{...options,signal:abort.signal});return {response,body:response.status===429?'':await readBounded(response,limit)};})();
    try{return await Promise.race([pending,new Promise((_,reject)=>{timer=setTimeout(()=>{abort.abort();reject(Error('Request timeout'));},15000);})]);}finally{clearTimeout(timer);}
  }
  async function maintainSession(userRequest=false) {
    if(!access||!['restored','session-paused','restoring'].includes(status))return false;
    if(restoring)return restoring;
    const now=serverNow(),visible=globalThis.document?.visibilityState==='visible',active=userRequest||visible;
    const lapsed=now>=expires;
    // Returning after the 5-minute access life: the tab's memory-only key signs the lineage head (no bearer, no
    // navigation). Without a key/lineage the existing first-party redirect remains the fallback.
    if(lapsed&&!(active&&signingKey&&renewal)){if(active&&Date.now()>=renewalRetryAt)return restoreSession();status='session-paused';return false;}
    if(!active||(!lapsed&&expires-now>60000))return true;
    if(!signingKey||!renewal)return true;
    // A signed cross-site response cannot extend the first-party cookie lifetime.
    if(Date.now()<renewalRetryAt)return !lapsed;
    // The signed key, not the first-party cookie, authorizes a live tab: cookie expiry alone never navigates.
    // It only matters on reload, a new tab or a lost key (those still use the first-party restore).
    if(renewing)return renewing;
    const attempt=generation,oldAccess=access,oldRenewal=renewal,key=signingKey;
    renewing=(async()=>{
      let responded=false;
      try {
        const expiresAt=serverNow()+30000;
        const message=new TextEncoder().encode([lapsed?'otpanda-renew-resume-v1':'otpanda-renew-v1','POST /auth/renew',oldRenewal.lineageId,oldRenewal.handleId,String(expiresAt)].join('\n'));
        const signature=encode(new Uint8Array(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,message)));
        if(attempt!==generation)return false;
        const renewalRead=await boundedRead(API+'/auth/renew',{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:lapsed?{'Content-Type':'application/json'}:{'Content-Type':'application/json',Authorization:'Bearer '+oldAccess},body:JSON.stringify(lapsed?{lineage_id:oldRenewal.lineageId,handle_id:oldRenewal.handleId,expires_at:expiresAt,signature}:{lineage_id:oldRenewal.lineageId,expires_at:expiresAt,signature})},4096);const response=renewalRead.response;responded=true;
        if(response.status===429){renewalRetryAt=Date.now()+60000;return serverNow()<expires;}
        if(!response.ok)throw Error('Renewal refused');
        const result=JSON.parse(renewalRead.body);const nextOffset=validateAccess(result,true);
        if(!result.renewal||result.renewal.lineageId!==oldRenewal.lineageId||result.renewal.handleId===oldRenewal.handleId||(result.renewal.firstPartyExpiresAt===undefined||result.renewal.firstPartyExpiresAt<oldRenewal.firstPartyExpiresAt))throw Error('Invalid successor');
        if(attempt!==generation||oldAccess!==access)return false;
        serverOffset=nextOffset;access=result.access;expires=result.accessExpiresAt;renewal=result.renewal;status='restored';return true;
      } catch {
        if(attempt!==generation)return false;
        // Away-and-back with no server answer at all (offline): keep the key and retry shortly, never navigate.
        if(lapsed&&!responded){renewalRetryAt=Date.now()+10000;return false;}
        // A lost response may have spent this handle. Keep its existing read
        // authority until expiry, but never retry it or navigate on a blip.
        signingKey=undefined;renewal=undefined;
        return serverNow()<expires;
      } finally {if(attempt===generation)renewing=undefined;}
    })();
    return renewing;
  }
  if(typeof globalThis.addEventListener==='function'){
    globalThis.addEventListener('pageshow',e=>{if(e.persisted){restoring=undefined;renewing=undefined;renewalRetryAt=0;if(access)status=serverNow()<expires?'restored':'session-paused';}});
  }
  const assertion=async c=>{
    const o=c.options,decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
    if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||o?.rpId!=='otpanda.github.io'||o.userVerification!=='required'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||!Array.isArray(o.allowCredentials)||o.allowCredentials.length>50||!Number.isSafeInteger(c.expiresAt)||c.expiresAt<=Date.now()||c.expiresAt>Date.now()+120000)throw Error('Invalid passkey verification');
    const credential=await navigator.credentials.get({publicKey:{rpId:'otpanda.github.io',challenge:decode(o.challenge),userVerification:'required',timeout:Math.min(120000,c.expiresAt-Date.now()),allowCredentials:o.allowCredentials.map(v=>({type:'public-key',id:decode(v.id)}))}});if(!credential)throw Error('Passkey verification cancelled');
    return{id:credential.id,rawId:encode(new Uint8Array(credential.rawId)),type:credential.type,clientExtensionResults:credential.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(credential.response.clientDataJSON)),authenticatorData:encode(new Uint8Array(credential.response.authenticatorData)),signature:encode(new Uint8Array(credential.response.signature)),userHandle:credential.response.userHandle?encode(new Uint8Array(credential.response.userHandle)):null}};
  };
  // Optional recovery bridge, loaded before this file. It gets narrow capabilities
  // only; the access token stays in this closure and is never handed to Flutter.
  const recovery=typeof globalThis.OTPandaRecoveryFactory==='function'?Object.freeze(globalThis.OTPandaRecoveryFactory({api:API,access:()=>serverNow()<expires?access:undefined,generation:()=>generation,readBounded,encode,decode:v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0)),random,fetchImpl:(...args)=>fetch(...args),credentials:{get:o=>navigator.credentials.get(o),create:o=>navigator.credentials.create(o)},storage:sessionStorage})):undefined;
  ready.then(()=>{if(typeof history.pushState==='function'&&(status==='restored'||(!pending&&status==='idle')))showRoute(route??ROUTES[Math.min(view,4)],true);},()=>{});
  // Optional realtime change hints. Inert unless realtime-client.js was loaded first. The hint carries no data:
  // listeners only re-read through the normal authorized reads. The ticket 401 path reuses the ordinary session read.
  const realtimeListeners=new Set(),connectionListeners=new Set();let lostShown=false;
  if(typeof globalThis.OTPandaRealtime?.create==='function'&&typeof globalThis.WebSocket==='function'){
    realtime=globalThis.OTPandaRealtime.create({api:API,fetch:(...a)=>fetch(...a),WebSocket:globalThis.WebSocket,document:globalThis.document,window:globalThis,epoch:()=>generation,
      getAccess:async()=>{if(!['restored','session-paused','restoring'].includes(status))return undefined;if(!await maintainSession(false))return undefined;return serverNow()<expires?access:undefined;},
      onUnauthorized:async()=>{await globalThis.OTPandaSession.read('/v1/manage/session');},
      onChanged:reason=>{for(const f of [...realtimeListeners]){try{f(reason);}catch{}}},
      onConnection:c=>{for(const f of [...connectionListeners]){try{f(c);}catch{}}const lost=c.status==='lost';if(lost===lostShown)return;lostShown=lost;for(const f of [...realtimeListeners]){try{f(lost?'connection-lost':'connection-restored');}catch{}}}});
  }
  Object.defineProperty(globalThis,'OTPandaSession',{value:Object.freeze({
    ready,
    recovery,
    assignmentPrepare:async target=>{if(!assignment)throw Error('Assignment unavailable');return JSON.stringify(await assignment.prepare(JSON.parse(target)));},
    assignmentConfirm:async()=>{if(!assignment)throw Error('Assignment unavailable');return assignment.confirm();},
    assignmentReconcile:async()=>{if(!assignment)throw Error('Assignment unavailable');return assignment.reconcile();},
    assignmentState:()=>assignment?.state??'unsupported',
    assignmentDismiss:()=>assignment?.dismiss(),
    status:()=>status,
    realtimeState:()=>realtime?.state()??'unsupported',
    realtimeConnection:()=>realtime?.connection()??Object.freeze({status:'ok',reason:undefined,retrying:false,since:0}),
    realtimeConnectionSubscribe:listener=>{if(typeof listener!=='function')throw Error('Listener required');connectionListeners.add(listener);return()=>{connectionListeners.delete(listener);};},
    realtimeSubscribe:listener=>{if(typeof listener!=='function')throw Error('Listener required');realtimeListeners.add(listener);if(lostShown){try{listener('connection-lost');}catch{}}if(realtime&&realtimeListeners.size===1)realtime.start();return()=>{realtimeListeners.delete(listener);if(realtime&&realtimeListeners.size===0)realtime.stop();};},
    maintain:()=>maintainSession(),
    accessExpiresAt:()=>expires-serverOffset,
    view:()=>view,
    setView:value=>{if(!validView(value))throw Error('View identifier required');view=value;try{sessionStorage.setItem(VIEW_KEY,String(value));}catch{}},
    email:()=>entryEmail,
    googleStart:async remember=>globalThis.OTPandaSession.start('google',remember),
    // Signed-in connect. Never clears the session or the restore hint. Returns
    // '' once it navigates to Google, otherwise a reason code to show.
    connectGoogle:async()=>{
      const attempt=generation;
      if(!await maintainSession(true)||attempt!==generation)return 'signin';
      const token=serverNow()<expires?access:undefined;if(!token)return 'signin';
      const state=random();
      let r;try{r=await fetch(API+'/v1/manage/google/link/ticket',{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({state})});}catch{return 'unavailable';}
      let v;try{v=JSON.parse(await readBounded(r,2048));}catch{return 'unavailable';}
      if(attempt!==generation)return 'unavailable';
      if(!r.ok)return r.status===429?'retry':r.status===409&&v?.error==='no_passkey'?'no_passkey':r.status===409&&v?.error==='already_linked'?'already_linked':r.status===401||r.status===403?'signin':'unavailable';
      if(typeof v?.ticket!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(v.ticket))return 'unavailable';
      try{sessionStorage.setItem(LINK_KEY,JSON.stringify({state,route:validRoute(route)&&route!=='demo'&&!route.startsWith('recovery')?route:'settings/account-security',created:Date.now()}));}catch{return 'unavailable';}
      location.assign(API+'/auth/google/link/start?'+new URLSearchParams({ticket:v.ticket}));return '';
    },
    googleLinkResult:()=>{const r=linkResult;linkResult=undefined;return r??'';},
    signupEmail:async(email,proof='')=>{
      if(location.origin+location.pathname!==REDIRECT||location.search||typeof email!=='string'||email.length>254||typeof proof!=='string'||(proof&&!/^otpda_[A-Za-z0-9_-]{55}$/.test(proof)&&! /^[A-HJ-NP-Z2-9]{8}$/i.test(proof.replaceAll(' ','').replaceAll('-',''))))throw Error('Valid signup details required');
      clear();const attempt=generation,verifier=random(),state=random(),challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));if(attempt!==generation)return;
      sessionStorage.setItem(KEY,JSON.stringify({verifier,state,...(route?{route}:{}),created:Date.now(),email}));
      const u=new URL(API+'/auth/signup/app');u.search=new URLSearchParams({challenge,state,redirect_uri:REDIRECT});u.hash=new URLSearchParams({action:proof?'begin':'email',email,...(proof?{email_token:proof}:{})});location.assign(u.href);
    },
    access:()=>{if(access!==undefined&&serverNow()>=expires){status='session-paused';return undefined;}return access;},
    clear:()=>{showRoute('codes',true);resetReadRestore();forgetView();forgetProfile();try{localStorage.removeItem('otpanda-session-present');}catch{}clear();status='idle';try{sessionStorage.removeItem(KEY);}catch{}},
    logout:()=>{showRoute('codes',true);resetReadRestore();forgetView();forgetProfile();try{localStorage.removeItem('otpanda-session-present');}catch{}clear();status='idle';try{sessionStorage.removeItem(KEY);}catch{}location.assign(API+'/auth/device/logout');},
    read:async path=>{
      if(!['/v1/manage/account','/v1/manage/session','/v1/manage/session?view=cache-v1','/v1/manage/entries','/v1/manage/active-codes','/v1/manage/sources','/v1/manage/unassigned'].includes(path))throw Error('Read path required');
      if(!await maintainSession(true))return {status:access||status==='restoring'||status==='session-paused'?503:401,body:'{}'};
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token)return {status:401,body:'{}'};
      const result=await boundedRead(API+path,{method:'GET',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token}},524288);const r=result.response,body=result.body;
      if(attempt!==generation)return {status:401,body:'{}'};
      if(r.status===401){await restoreAfterUnauthorized();return {status:503,body:'{}'};}
      const raw=r.headers?.get('Retry-After');
      let retryAfterSeconds=null;
      if(raw){
        const seconds=/^\d+$/.test(raw.trim())?Number(raw):Math.ceil((Date.parse(raw)-Date.now())/1000);
        if(Number.isSafeInteger(seconds)&&seconds>=0)retryAfterSeconds=seconds;
      }
      return {status:r.status,body,retryAfterSeconds};
    },
    organize:async(method,body='')=>{
      if(!['GET','PUT'].includes(method)||typeof body!=='string'||new TextEncoder().encode(body).byteLength>131072||(method==='GET'&&body))throw Error('Organization request required');
      if(!await maintainSession(true))return {status:access||status==='restoring'||status==='session-paused'?503:401,body:'{}'};
      const attempt=generation,token=serverNow()<expires?access:undefined;
      if(!token)return {status:401,body:'{}'};
      const r=await fetch(API+'/v1/manage/organization',{method,credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,...(method==='PUT'?{'Content-Type':'application/json'}:{})},...(method==='PUT'?{body}:{})});
      const text=await readBounded(r,524288);if(attempt!==generation)return {status:401,body:'{}'};
      if(r.status===401){await restoreAfterUnauthorized();return {status:503,body:'{}'};}return {status:r.status,body:text};
    },
    copied:async(entryId,createdAt)=>{
      if(typeof entryId!=='string'||!entryId||entryId.length>256||!Number.isSafeInteger(createdAt))throw Error('Copy receipt required');
      if(!await maintainSession(true))return {status:access||status==='restoring'||status==='session-paused'?503:401,body:'{}'};
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token)return {status:401,body:'{}'};
      const receiptId=random();
      const r=await fetch(API+'/v1/manage/organization-copy',{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({entryId,receiptId,createdAt})});
      const body=await readBounded(r,4096);if(attempt!==generation)return {status:401,body:'{}'};
      if(r.status===401){await restoreAfterUnauthorized();return {status:503,body:'{}'};}return {status:r.status,body};
    },
    pendingLabel:()=>protectionPending?.pendingId.slice(0,6).toUpperCase()??'',
    protectionContinue:async action=>{
      const p=protectionPending,attempt=generation;if(!p||p.expiresAt<=Date.now()||!['passkey','check'].includes(action))throw Error('Start sign-in again.');
      const post=async(path,value)=>{const r=await fetch(API+'/auth/google/protection/'+path,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-OTPanda-Pending':p.token},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,16384));if(!r.ok||attempt!==generation)throw Error('Verification expired. Start sign-in again.');return v;};
      if(action==='passkey'){const c=await post('begin',{}),response=await assertion(c);if(attempt!==generation)return;await post('verify',{token:c.token,response});}
      const value=await post('status',{});if(value.status==='waiting')return 'waiting';if(value.status!=='approved')throw Error('Verification expired.');if(attempt!==generation)return 'cancelled';sessionStorage.setItem(KEY,JSON.stringify({...p.saved,created:Date.now()}));protectionPending=undefined;location.assign(API+'/auth/google/protection/complete#'+new URLSearchParams({token:p.token}));return 'approved';
    },
    security:async(action,enabled=false,pendingId='')=>{
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token||!['status','toggle','approve','deny','request-change','approve-change','consume-change'].includes(action))throw Error('Sign in again.');
      const post=async(path,value)=>{const r=await fetch(API+'/v1/manage/security/'+path,{method:path==='status'?'GET':'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,...(path==='status'?{}:{'Content-Type':'application/json'})},...(path==='status'?{}:{body:JSON.stringify(value)})});const v=JSON.parse(await readBounded(r,16384));if(!r.ok||attempt!==generation)throw Error('Security update did not finish. Try again.');return v;};
      if(action==='status')return JSON.stringify(await post('status'));
      if(action==='request-change')return JSON.stringify(await post(action,{enabled,warningAccepted:true}));
      if(action==='approve-change'||action==='consume-change')return JSON.stringify(await post(action,{changeId:pendingId}));
      if(action==='approve'||action==='deny'){await post(action,{pendingId});return '{}';}
      const value={enabled,warningAccepted:true},c=await post('begin',value),response=await assertion(c);if(attempt!==generation)return '{}';await post('finish',{...value,token:c.token,response});return '{}';
    },
    googleContinue:async(action,proof='')=>{
      if(googlePending?.linkOnly){
        const g=googlePending,attempt=generation;
        if(action==='link-cancel'){googlePending=undefined;await startRestore('cancelled');return;}
        if(action!=='link-only')throw Error('Verify with your passkey or cancel.');
        if(g.expiresAt<=Date.now()){googlePending=undefined;await startRestore('restart');return;}
        const post=async(path,value)=>{const r=await fetch(API+'/auth/google/continue/'+path,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-OTPanda-Continuation':g.token},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,16384));if(!r.ok)throw Error('refused');return v;};
        let c,credential;
        const decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),x=>x.charCodeAt(0));
        try{
          c=await post('begin',{});const o=c.options;
          if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||o?.rpId!=='otpanda.github.io'||o.userVerification!=='required'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||!Array.isArray(o.allowCredentials)||o.allowCredentials.length>20)throw Error('invalid');
          if(attempt!==generation)return;
          try{credential=await navigator.credentials.get({publicKey:{rpId:'otpanda.github.io',challenge:decode(o.challenge),userVerification:'required',timeout:120000,allowCredentials:o.allowCredentials.map(v=>({type:'public-key',id:decode(v.id)}))}});}catch{credential=null;}
        }catch{if(attempt===generation){googlePending=undefined;await startRestore('restart');}return;}
        // Dismissed prompt: keep the pending link so the person can try again or cancel.
        if(!credential||attempt!==generation)throw Error('Account verification cancelled');
        try{
          const done=await post('verify',{ceremony:c.token,emailProof:'',response:{id:credential.id,rawId:encode(new Uint8Array(credential.rawId)),type:credential.type,clientExtensionResults:credential.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(credential.response.clientDataJSON)),authenticatorData:encode(new Uint8Array(credential.response.authenticatorData)),signature:encode(new Uint8Array(credential.response.signature)),userHandle:credential.response.userHandle?encode(new Uint8Array(credential.response.userHandle)):null}}});
          if(done?.status!=='ok')throw Error('refused');
        }catch{if(attempt===generation){googlePending=undefined;await startRestore('restart');}return;}
        if(attempt!==generation)return;
        googlePending=undefined;await startRestore('connected');return;
      }
      if(action==='link-only'||action==='link-cancel')throw Error('Start Google sign-in again.');
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
    gmailSourceStatus:async()=>{
      if(!await maintainSession(true))return {status:401,body:'{}'};
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token)return {status:401,body:'{}'};
      const r=await boundedRead(API+'/v1/manage/gmail-source/status',{method:'GET',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token}},2048);
      if(attempt!==generation)return {status:401,body:'{}'};
      if(r.response.status===404||r.response.status===503)return {status:200,body:JSON.stringify({ready:false,passkeyRequired:false})};
      return {status:r.response.status,body:r.body};
    },
    connectGmail:async()=>{
      if(!await maintainSession(true))throw Error('Sign in again');
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token)throw Error('Sign in again');
      const post=async(suffix,value)=>{const r=await fetch(API+'/v1/manage/gmail-source'+suffix,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,16384));if(!r.ok||attempt!==generation)throw Error('Gmail was not connected');return v;};
      const value={action:'connect',sourceId:''},c=await post('/begin',value),response=await assertion(c);if(attempt!==generation)throw Error('Cancelled');
      const r=await post('',{...value,token:c.token,response});
      if(r.ok!==true||typeof r.authorizationUrl!=='string'||r.authorizationUrl.length>8192)throw Error('Invalid Google authorization');
      const u=new URL(r.authorizationUrl);
      const allowed=['client_id','redirect_uri','response_type','scope','access_type','prompt','include_granted_scopes','state','code_challenge','code_challenge_method'];
      if([...u.searchParams.keys()].some(k=>!allowed.includes(k))||allowed.some(k=>u.searchParams.getAll(k).length!==1)||u.searchParams.get('access_type')!=='offline'||u.searchParams.get('prompt')!=='consent'||u.searchParams.get('include_granted_scopes')!=='false')throw Error('Invalid Google authorization');
      if(u.origin!=='https://accounts.google.com'||u.pathname!=='/o/oauth2/v2/auth'||u.username||u.password||u.hash||!sameScopes(u.searchParams.get('scope'))||u.searchParams.get('redirect_uri')!==API+'/sources/gmail/oauth/callback'||u.searchParams.get('client_id')!=='367143149550-cu61adcdqclntipnl84e096kp35vduvk.apps.googleusercontent.com'||u.searchParams.get('response_type')!=='code'||u.searchParams.get('code_challenge_method')!=='S256'||!/^[0-9a-f]{64}$/.test(u.searchParams.get('state')??'')||!/^[A-Za-z0-9_-]{43}$/.test(u.searchParams.get('code_challenge')??''))throw Error('Invalid Google authorization');
      if(attempt!==generation)throw Error('Cancelled');location.assign(u.href);
    },
    disconnectGmail:async sourceId=>{
      if(typeof sourceId!=='string'||!/^[a-zA-Z0-9_-]{1,128}$/.test(sourceId))throw Error('Source required');
      if(!await maintainSession(true))throw Error('Sign in again');
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token)throw Error('Sign in again');
      const post=async(suffix,value)=>{const r=await fetch(API+'/v1/manage/gmail-source'+suffix,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,16384));if(!r.ok||attempt!==generation)throw Error('Gmail was not disconnected');return v;};
      const value={action:'disconnect',sourceId},c=await post('/begin',value),response=await assertion(c);if(attempt!==generation)throw Error('Cancelled');const r=await post('',{...value,token:c.token,response});
      if(r.disconnected!==true&&!(r.disconnected===false&&r.lifecycleBlocked===true))throw Error('Gmail was not disconnected');
      return JSON.stringify({disconnected:r.disconnected===true,googlePermissionRemains:r.googlePermissionRemains!==false,lifecycleBlocked:r.lifecycleBlocked===true,...(typeof r.artifactsRemoved==='boolean'?{artifactsRemoved:r.artifactsRemoved}:{})});
    },
    addTotp:async(label,account,secret)=>{
      if(typeof label!=='string'||!label.trim()||label.length>120||typeof account!=='string'||account.length>120||typeof secret!=='string'||secret.length>2048)throw Error('Invalid authenticator details');
      if(!await maintainSession(true))throw Error('Sign in again');
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token)throw Error('Sign in again');
      const post=async(suffix,value)=>{const r=await fetch(API+'/v1/manage/totp'+suffix,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,24576));if(!r.ok||attempt!==generation)throw Error('Authenticator setup did not finish. Check details and verify with a passkey.');return v;};
      const value={label,account,secret};try{const c=await post('/begin',value),response=await assertion(c);if(attempt!==generation)throw Error('Cancelled');const result=await post('',{...value,token:c.token,response});if(typeof result.entryId!=='string'||result.entryId.length>256)throw Error('Invalid result');return result.entryId;}finally{value.secret='';secret='';}
    },
    totpCode:async entryId=>{
      if(typeof entryId!=='string'||!entryId||entryId.length>256)throw Error('Entry required');
      if(!await maintainSession(true))return {status:401,body:'{}'};
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token)return {status:401,body:'{}'};
      const result=await boundedRead(API+'/v1/manage/totp-code?'+new URLSearchParams({entry:entryId}),{method:'GET',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token}},4096);if(attempt!==generation)return {status:401,body:'{}'};return {status:result.response.status,body:result.body};
    },
    profileRead:(ownerId,sessionId)=>{
      try{
        if(profileRevoked||status!=='restored'||localStorage.getItem('otpanda-session-present')!=='yes'||typeof ownerId!=='string'||!/^[0-9a-f]{64}$/.test(sessionId))return '';
        const raw=localStorage.getItem(PROFILE_KEY);if(raw===null)return '';
        const v=raw.length<=4096?JSON.parse(raw):null,keys=v&&typeof v==='object'?Object.keys(v).sort().join(','):'';
        if(!['email,ownerId,savedAt,sessionId','email,ownerId,picture,savedAt,sessionId'].includes(keys)||v.ownerId!==ownerId||v.sessionId!==sessionId||typeof v.email!=='string'||!v.email||v.email.length>254||!Number.isSafeInteger(v.savedAt)||(v.picture!==undefined&&(typeof v.picture!=='string'||v.picture.length>2048))){forgetProfile();return '';}
        return JSON.stringify({email:v.email,...(v.picture===undefined?{}:{picture:v.picture}),savedAt:v.savedAt});
      }catch{forgetProfile();return '';}
    },
    profileWrite:(ownerId,sessionId,email,picture)=>{
      try{
        // A late response after sign-out finds the flag gone and writes nothing.
        if(profileRevoked||status!=='restored'||localStorage.getItem('otpanda-session-present')!=='yes')return;
        if(typeof ownerId!=='string'||!ownerId||ownerId.length>256||!/^[0-9a-f]{64}$/.test(sessionId)||typeof email!=='string'||!email||email.length>254||/[\u0000-\u001f\u007f]/.test(email))return;
        let pic;if(typeof picture==='string'&&picture.length<=2048){try{const u=new URL(picture);if(u.protocol==='https:'&&!u.username&&!u.password&&(u.hostname==='googleusercontent.com'||u.hostname.endsWith('.googleusercontent.com')))pic=picture;}catch{}}
        localStorage.setItem(PROFILE_KEY,JSON.stringify({ownerId,sessionId,email,...(pic===undefined?{}:{picture:pic}),savedAt:Date.now()}));
      }catch{}
    },
    profileClear:forgetProfile,
    profileRevoked:()=>profileRevoked,
    onProfileRevoked:f=>{if(typeof f!=='function')return;revokeListeners.add(f);},
    addPasskey:async()=>{
      const attempt=generation,token=serverNow()<expires?access:undefined;if(!token)throw Error('Sign in again.');
      const post=async(step,value,grant)=>{const r=await fetch(API+'/v1/manage/passkey/add/'+step,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',...(grant?{'X-OTPanda-Enrollment':grant}:{})},body:JSON.stringify(value)});const v=JSON.parse(await readBounded(r,24576));if(!r.ok||attempt!==generation)throw Error('Passkey setup could not finish. Start again.');return v;};
      const verification=await post('verify-begin',{}),response=await assertion(verification);if(attempt!==generation)throw Error('Cancelled');const grant=await post('verify-finish',{token:verification.token,response});if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(grant.token)||!Number.isSafeInteger(grant.expiresAt)||grant.expiresAt<=Date.now()||grant.expiresAt>Date.now()+120000)throw Error('Invalid authorization');
      const c=await post('register-begin',{},grant.token),o=c.options,decode=v=>Uint8Array.from(atob(v.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
      if(!/^otpda_[A-Za-z0-9_-]{55}$/.test(c.token)||o?.rp?.id!=='otpanda.github.io'||o.rp.name!=='OTPanda'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||!Number.isSafeInteger(c.expiresAt)||c.expiresAt<=Date.now()||c.expiresAt>Date.now()+120000||o.authenticatorSelection?.userVerification!=='required'||!Array.isArray(o.excludeCredentials)||o.excludeCredentials.length>10||o.excludeCredentials.some(v=>v.type!=='public-key'||typeof v.id!=='string'||!/^[A-Za-z0-9_-]{1,1400}$/.test(v.id)))throw Error('Invalid passkey setup');
      const credential=await navigator.credentials.create({publicKey:{rp:o.rp,user:{...o.user,id:decode(o.user.id)},challenge:decode(o.challenge),pubKeyCredParams:[{type:'public-key',alg:-7},{type:'public-key',alg:-257}],timeout:Math.min(120000,c.expiresAt-Date.now()),attestation:'none',authenticatorSelection:{residentKey:'required',userVerification:'required'},excludeCredentials:o.excludeCredentials.map(v=>({type:'public-key',id:decode(v.id)}))}});if(attempt!==generation||!credential||credential.type!=='public-key')throw Error('Cancelled');
      await post('register-finish',{token:c.token,response:{id:credential.id,rawId:encode(new Uint8Array(credential.rawId)),type:credential.type,clientExtensionResults:credential.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(credential.response.clientDataJSON)),attestationObject:encode(new Uint8Array(credential.response.attestationObject)),transports:credential.response.getTransports?.()??[]}}},grant.token);
    },
    firstPasskeyAvailable:()=>Boolean(enrollment&&serverNow()<expires),
    firstPasskey:async()=>{
      const attempt=generation,grant=enrollment,token=serverNow()<expires?access:undefined;if(!grant||!token)throw Error('Sign in with Google again to add your first passkey.');
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
      if(mode!=='restore'){forgetView();forgetProfile();profileRevoked=false;}
      clear();const attempt=generation,verifier=random(),state=random(),challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
      if(attempt!==generation)return;
      sessionStorage.setItem(KEY,JSON.stringify({verifier,state,...(route?{route}:{}),created:Date.now(),...(mode==='restore'?{view}:{})}));
      const url=new URL(API+(mode==='google'?'/auth/google/start':mode==='signup'?'/auth/signup/start':mode==='login'?'/auth/login/start':'/auth/restore'));url.search=new URLSearchParams({challenge,state,redirect_uri:REDIRECT,...(mode==='google'?{remember:remember?'yes':'no'}:{})});location.assign(url.href);
    },
  }),writable:false,configurable:false});
})();
