// Exact site matching for autofill. A page matches an entry only when its normalized HTTPS hostname is EXACTLY one of that entry's domains
// (service domains from the catalogue UNION the viewer's own associations). No parent-domain, subdomain, wildcard, suffix or lookalike expansion.
// Matching selects eligible entries only. It never releases a code.
const LABEL=/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
// Returns the canonical ASCII hostname for a bare domain string, or undefined. Rejects schemes, paths, ports, userinfo, wildcards, IPs, single labels.
export function normalizeDomain(value){
 if(typeof value!=='string'||!value||value.length>253||/[\s/\\?#@:*%\u0000-\u001f\u007f]/.test(value))return undefined;
 let host;try{const u=new URL('https://'+value);if(u.username||u.password||u.port||u.pathname!=='/'||u.search||u.hash)return undefined;host=u.hostname;}catch{return undefined;}
 if(host.endsWith('.'))host=host.slice(0,-1);
 const labels=host.split('.');
 if(labels.length<2||labels.some(l=>!LABEL.test(l))||/^\d+$/.test(labels[labels.length-1]))return undefined;// no IPv4-like hosts, no bare labels
 return host;
}
// Hostname of an https page URL a browser reported, or undefined. Non-default ports, userinfo, IP hosts and non-https are never eligible.
export function pageHost(url){
 if(typeof url!=='string'||url.length>2048)return undefined;
 let u;try{u=new URL(url);}catch{return undefined;}
 if(u.protocol!=='https:'||u.username||u.password||u.port)return undefined;
 let host=u.hostname;if(host.endsWith('.'))host=host.slice(0,-1);
 if(host.startsWith('[')||!host.includes('.'))return undefined;
 return normalizeDomain(host);
}
// entries: [{entryId, domains:[string]}]. Returns entryIds whose domain list contains the page host exactly.
export function eligibleEntries(url,entries){
 const host=pageHost(url);if(!host||!Array.isArray(entries))return [];
 const out=[];
 for(const e of entries){
  if(!e||typeof e.entryId!=='string'||!Array.isArray(e.domains))continue;
  if(e.domains.some(d=>normalizeDomain(d)===host))out.push(e.entryId);
 }
 return out;
}
// Content-script match patterns, one exact host each (https://host/*). Deduplicated and bounded. Invalid domains are dropped.
export function matchPatterns(entries,{max=5000}={}){
 const set=new Set();
 for(const e of Array.isArray(entries)?entries:[])for(const d of Array.isArray(e?.domains)?e.domains:[]){const h=normalizeDomain(d);if(h)set.add('https://'+h+'/*');if(set.size>=max)return [...set];}
 return [...set];
}
