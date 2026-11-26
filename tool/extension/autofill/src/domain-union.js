// Per-entry autofill domain set: the exact domains the 2FA Directory lists for the entry's chosen catalogue row (primary plus additional),
// UNION the viewer's own associations. Pure and inert: no network, storage, permission or code release. Output feeds match.js, which does the
// exact host equality. Rules:
//  - Catalogue domains come only from an exact catalogId == a row's primary domain lookup in the caller's fetched catalogue. Never from the
//    display name, label, logo, issuer or any fuzzy match. An unknown id, or a primary shared by two rows, contributes nothing.
//  - Associations come only from the viewer's own private store, passed separately keyed by entryId. Fields on the entry itself (including
//    anything an owner shared) are never read as associations.
//  - Every domain is normalized by match.js normalizeDomain (exact host, no wildcard, parent, subdomain or suffix expansion).
import {normalizeDomain} from './match.js';
const ID=/^[a-z0-9][a-z0-9._-]{0,127}$/;
export const LIMITS=Object.freeze({rows:5000,hostsPerRow:50,associationsPerEntry:20});
// rows: the cached catalogue rows [{n,d:[primary,...additional],i}] as ServiceDirectory stores them.
export function buildCatalogIndex(rows){
 const index=new Map(),ambiguous=new Set();
 for(const r of Array.isArray(rows)?rows.slice(0,LIMITS.rows):[]){
  if(!r||!Array.isArray(r.d)||!r.d.length)continue;
  const hosts=[];for(const d of r.d.slice(0,LIMITS.hostsPerRow)){const h=normalizeDomain(d);if(!h)break;hosts.push(h);}
  if(hosts.length!==Math.min(r.d.length,LIMITS.hostsPerRow))continue;// a row with any invalid listed domain is dropped whole
  const primary=hosts[0];
  if(index.has(primary)||ambiguous.has(primary)){index.delete(primary);ambiguous.add(primary);continue;}
  index.set(primary,[...new Set(hosts)]);
 }
 return index;
}
// One entry's domains. ownAssociations: array of domain strings the viewer typed for this entry (bounded, invalid dropped).
export function entryDomains(catalogId,ownAssociations,index){
 const out=new Set();
 if(typeof catalogId==='string'&&ID.test(catalogId)&&index instanceof Map)for(const h of index.get(catalogId)??[])out.add(h);
 for(const a of Array.isArray(ownAssociations)?ownAssociations.slice(0,LIMITS.associationsPerEntry):[]){const h=normalizeDomain(a);if(h)out.add(h);}
 return [...out].sort();
}
// entries: [{entryId, catalogId?}] from the signed-in read. associationsByEntryId: Map or plain object of the viewer's own associations.
// Returns [{entryId, domains}] for match.js; entries with no domain are omitted.
export function autofillEntries(entries,index,associationsByEntryId){
 const own=associationsByEntryId instanceof Map?associationsByEntryId:new Map(Object.entries(associationsByEntryId&&typeof associationsByEntryId==='object'?associationsByEntryId:{}));
 const out=[],seen=new Set();
 for(const e of Array.isArray(entries)?entries:[]){
  if(!e||typeof e.entryId!=='string'||!e.entryId||seen.has(e.entryId))continue;
  seen.add(e.entryId);
  const domains=entryDomains(e.catalogId,own.get(e.entryId),index);
  if(domains.length)out.push({entryId:e.entryId,domains});
 }
 return out;
}
// Adapter for the API's viewer-private read: GET /v1/manage/entry/domains answers {associations:[{entryId,domains:[...]}]} (entry-domains-http.js).
// Only the viewer's own associations, at most 1000 entries and 32 domains each, already normalized server side; no catalogue domains are merged in.
// Takes the {status, body} read result (body is the JSON text) or an already parsed object. Returns a Map entryId -> domains, or undefined when the
// response is not a clean 200 of that exact shape (the caller then uses no associations; it must not reuse stale ones as if current).
const ENTRY_ID=/^[A-Za-z0-9_-]{1,128}$/,PRIVATE_SUFFIX=['.local','.localhost','.internal'];
export function associationsFromResponse(response){
 let data=response;
 if(response&&typeof response==='object'&&'status' in response){
  if(response.status!==200||typeof response.body!=='string'||response.body.length>1048576)return undefined;
  try{data=JSON.parse(response.body);}catch{return undefined;}
 }
 if(!data||typeof data!=='object'||Array.isArray(data)||Object.keys(data).join()!=='associations'||!Array.isArray(data.associations)||data.associations.length>1000)return undefined;
 const out=new Map();
 for(const a of data.associations){
  if(!a||typeof a!=='object'||typeof a.entryId!=='string'||!ENTRY_ID.test(a.entryId)||out.has(a.entryId)||!Array.isArray(a.domains)||a.domains.length>32)continue;
  const domains=[];
  for(const d of a.domains){const h=normalizeDomain(d);if(h&&!PRIVATE_SUFFIX.some(s=>h.endsWith(s)))domains.push(h);}
  out.set(a.entryId,[...new Set(domains)].sort());
 }
 return out;
}
