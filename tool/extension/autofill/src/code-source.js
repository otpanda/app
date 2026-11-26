// Inert CodeSource for background.js createBackground({source}). Nothing here is packaged, registers a content script, asks for a host
// permission or persists a private value. Every dependency is injected so it runs in node tests and, later, in the sign-in worker where
// `read` is extension-auth's read(path) (GET only, exactly the three allowlisted routes) and `fetchText` is fetch.
//  - entries(): per call, reads /v1/manage/entries and /v1/manage/entry/domains, then returns [{entryId,domains}] from domain-union.js.
//    Nothing from those reads is kept between calls: a failed or non-200 viewer-association read means CATALOGUE domains only for that call
//    (never a remembered earlier answer). Only catalogId is used as the catalogue key (never the label, issuer, logo or the legacy service_id).
//  - code(entryId): reads /v1/manage/active-codes and returns the newest still-active record for exactly that entry. fill-request.js still
//    applies its own freshness, single-match and sender checks. Codes are never cached or stored.
//  - createCatalogueCache: the public 2FA Directory file, fetched and cached under the approved client-only rules (7 day TTL, 2 MiB, last
//    good kept on failure). It holds public catalogue rows only, never an entry, domain association, code or token.
import {buildCatalogIndex,autofillEntries,associationsFromResponse} from './domain-union.js';
export const CATALOGUE_URL='https://api.2fa.directory/v3/all.json';
export const CATALOGUE_LIMITS=Object.freeze({bytes:2*1024*1024,rows:5000,ttlMs:7*24*3600*1000,retryMs:10*60*1000});
const HOST=/^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/,ID=/^[a-z0-9][a-z0-9._-]{0,127}$/,ENTRY_ID=/^[A-Za-z0-9_-]{1,128}$/;
const MAX_ENTRIES=5000;
// Upstream v3 file: [[name,{domain,'additional-domains'?,...}],...] -> cached rows [{n,d:[primary,...additional]}]. Bad rows are skipped.
export function parseUpstream(text){
 if(typeof text!=='string'||text.length>CATALOGUE_LIMITS.bytes)throw Error('catalogue size');
 const data=JSON.parse(text);if(!Array.isArray(data)||!data.length||data.length>CATALOGUE_LIMITS.rows)throw Error('catalogue shape');
 const rows=[];
 for(const r of data){
  if(!Array.isArray(r)||r.length!==2||typeof r[0]!=='string'||!r[1]||typeof r[1]!=='object')continue;
  const v=r[1];if(typeof v.domain!=='string'||v.domain.length>253||!HOST.test(v.domain))continue;
  const d=[v.domain];
  if(Array.isArray(v['additional-domains']))for(const h of v['additional-domains'])if(typeof h==='string'&&h.length<=253&&HOST.test(h)&&!d.includes(h)&&d.length<50)d.push(h);
  rows.push({n:r[0].slice(0,120),d});
 }
 if(!rows.length)throw Error('catalogue empty');
 return rows;
}
// Reads at most max bytes: a Content-Length over max is refused before reading, and a stream is cancelled the moment the running byte count passes
// max (so an oversized or lying body is never buffered). Responses without a stream (test doubles) fall back to text() with a length check.
export async function readBounded(res,max){
 const cl=Number(res.headers&&typeof res.headers.get==='function'?res.headers.get('content-length'):NaN);
 if(Number.isFinite(cl)&&cl>max)throw Error('catalogue size');
 const reader=res.body&&typeof res.body.getReader==='function'?res.body.getReader():undefined;
 if(!reader){const t=await res.text();if(typeof t!=='string'||t.length>max)throw Error('catalogue size');return t;}
 const chunks=[];let n=0;
 for(;;){
  const {done,value}=await reader.read();if(done)break;
  n+=value.byteLength;if(n>max){try{await reader.cancel();}catch{/* already closed */}throw Error('catalogue size');}
  chunks.push(value);
 }
 const all=new Uint8Array(n);let o=0;for(const c of chunks){all.set(c,o);o+=c.byteLength;}
 return new TextDecoder('utf-8',{fatal:true}).decode(all);
}
// store: {get():Promise<{at,rows}|undefined>, set(value):Promise<void>}. fetchText(url): Promise<{ok,status,text()}> with no credentials.
export function createCatalogueCache({fetchText,store,clock=Date.now}){
 let memory,failedAt=-Infinity,inflight;
 const valid=v=>v&&Number.isSafeInteger(v.at)&&Array.isArray(v.rows)&&v.rows.length>0&&v.rows.length<=CATALOGUE_LIMITS.rows;
 async function refresh(){
  const now=clock();
  try{
   const res=await fetchText(CATALOGUE_URL);
   if(!res||res.ok!==true||res.status!==200)throw Error('status');
   const rows=parseUpstream(await readBounded(res,CATALOGUE_LIMITS.bytes));
   memory={at:now,rows};
   try{await store.set(memory);}catch{/* the in-memory copy still serves this worker run */}
  }catch{failedAt=now;}
 }
 // Returns the cached rows, refreshing when older than the TTL. A failed refresh keeps the last good rows and is not retried for 10 minutes.
 return {async rows(){
  const now=clock();
  if(!memory){try{const v=await store.get();if(valid(v))memory={at:v.at,rows:v.rows};}catch{/* no stored copy */}}
  const stale=!memory||now-memory.at>=CATALOGUE_LIMITS.ttlMs||memory.at>now;
  if(stale&&now-failedAt>=CATALOGUE_LIMITS.retryMs){inflight??=refresh().finally(()=>{inflight=undefined;});await inflight;}
  return memory?memory.rows:undefined;
 }};
}
function parseJson(res,max=524288){
 if(!res||res.status!==200||typeof res.body!=='string'||res.body.length>max)return undefined;
 try{const v=JSON.parse(res.body);return v&&typeof v==='object'&&!Array.isArray(v)?v:undefined;}catch{return undefined;}
}
// TOTP on demand. code() is called by fill-request.js once per host-matched entry, per fill request. A recently received code
// (SMS/email, event-driven) wins and costs no extra read. Otherwise ONE GET /v1/manage/totp-code?entry=ID is made for that matched entry only:
// never per hint, never from the popup, never for all entries. Expiry uses the server window minus the FULL round trip, counted on a monotonic
// clock, so a slow response or a wall-clock jump cannot extend the code. Nothing is cached. A 429 blocks further generated reads until its
// Retry-After (monotonic) has passed. An unmatched or unreadable entry gives 'no code' and the fill releases nothing.
const RECENT_MS=5*60_000,GEN=/^\d{6}(?:\d{2})?$/;
export function createCodeSource({read,catalogue,clock=Date.now,mono=()=>performance.now()}){
 let blockedUntil=-Infinity;
 async function generated(entryId){
  if(mono()<blockedUntil)throw Error('rate limited');
  const t0=mono(),res=await read('/v1/manage/totp-code?entry='+entryId),rtt=Math.max(0,mono()-t0);
  if(res&&res.status===429){blockedUntil=mono()+1000*Math.max(1,Math.min(3600,Number.isSafeInteger(res.retryAfter)?res.retryAfter:60));throw Error('rate limited');}
  const b=parseJson(res,4096);
  if(!b||b.entryId!==entryId||typeof b.code!=='string'||!GEN.test(b.code)||![b.validFrom,b.validUntil,b.period].every(Number.isSafeInteger)||!Number.isSafeInteger(b.serverNow)||b.period<1||b.validUntil-b.validFrom!==b.period)throw Error('no code');
  const age=b.serverNow-b.validFrom*1000,remaining=b.validUntil*1000-b.serverNow-rtt;
  if(age<0||remaining<=0)throw Error('expired');
  const now=clock();
  return {entryId,code:b.code,receivedAt:now-age-rtt,expiresAt:now+remaining};
 }
 return Object.freeze({
  async entries(){
   const body=parseJson(await read('/v1/manage/entries'));
   if(!body||!Array.isArray(body.entries)||body.entries.length>MAX_ENTRIES)throw Error('entries');
   const entries=[];
   for(const e of body.entries){
    if(!e||typeof e.entry_id!=='string'||!ENTRY_ID.test(e.entry_id))continue;
    entries.push({entryId:e.entry_id,catalogId:typeof e.catalogId==='string'&&ID.test(e.catalogId)?e.catalogId:undefined});
   }
   // Either source failing REJECTS (401, network, bad shape, no catalogue yet): a partial candidate set must never look like the full one, because the
   // worker revokes granted origins that are no longer candidates. A rejected entries() unregisters injection and changes no grant.
   let own;try{own=associationsFromResponse(await read('/v1/manage/entry/domains'));}catch{own=undefined;}
   if(!own)throw Error('associations');
   let rows;try{rows=await catalogue.rows();}catch{rows=undefined;}
   if(!rows)throw Error('catalogue');
   return autofillEntries(entries,buildCatalogIndex(rows),own);
  },
  async code(entryId){
   if(typeof entryId!=='string'||!ENTRY_ID.test(entryId))throw Error('entry');
   const body=parseJson(await read('/v1/manage/active-codes'));
   if(!body||!Array.isArray(body.records)||body.records.length>1000)throw Error('codes');
   let best;
   for(const r of body.records){
    if(!r||r.entryId!==entryId||typeof r.code!=='string'||!Number.isSafeInteger(r.receivedAt)||!Number.isSafeInteger(r.expiresAt)||r.expiresAt<=r.receivedAt)continue;
    if(!best||r.receivedAt>best.receivedAt)best={entryId:r.entryId,code:r.code,receivedAt:r.receivedAt,expiresAt:r.expiresAt};
   }
   if(best&&best.expiresAt>clock()&&clock()-best.receivedAt<=RECENT_MS)return best;
   try{return await generated(entryId);}catch(e){if(best&&best.expiresAt>clock())return best;throw e;}
  },
 });
}
