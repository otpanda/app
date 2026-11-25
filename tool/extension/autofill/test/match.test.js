import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeDomain, pageHost, eligibleEntries, matchPatterns } from '../src/match.js';
const entries=[{entryId:'gh',domains:['github.com','GitHub.com.']},{entryId:'acct',domains:['accounts.example.com']},{entryId:'bad',domains:['*.example.org','https://example.net','example.com/path','localhost','1.2.3.4','a_b.com','']},{entryId:'idn',domains:['bücher.example']}];
test('domains normalize to canonical ASCII hosts; schemes, paths, ports, wildcards, IPs, single labels are rejected',()=>{
 assert.equal(normalizeDomain('GitHub.com'),'github.com');assert.equal(normalizeDomain('github.com.'),'github.com');assert.equal(normalizeDomain('bücher.example'),'xn--bcher-kva.example');
 for(const bad of ['*.a.com','https://a.com','a.com/x','a.com:8443','user@a.com','localhost','1.2.3.4','[::1]','a_b.com','','a..com','-a.com','a.com?x','a com',' a.com','x'.repeat(300)+'.com',null,5])assert.equal(normalizeDomain(bad),undefined,String(bad));
});
test('only https pages on a clean default-port host are eligible',()=>{
 assert.equal(pageHost('https://github.com/login'),'github.com');assert.equal(pageHost('https://GitHub.com:443/x'),'github.com');
 for(const bad of ['http://github.com/','https://github.com:8443/','https://u:p@github.com/','https://1.2.3.4/','https://[::1]/','https://localhost/','ftp://github.com','chrome://x','not a url','data:text/html,x',null,'https://'+'a'.repeat(300)+'.com/'])assert.equal(pageHost(bad),undefined,String(bad));
});
test('matching is EXACT host equality: no parent, subdomain, wildcard, suffix or lookalike expansion',()=>{
 assert.deepEqual(eligibleEntries('https://github.com/session',entries),['gh']);
 assert.deepEqual(eligibleEntries('https://accounts.example.com/',entries),['acct']);
 for(const url of ['https://www.github.com/','https://gist.github.com/','https://github.com.evil.example/','https://evilgithub.com/','https://github.co/','https://example.com/','https://login.accounts.example.com/','https://github.com@evil.example/','https://githuЬ.com/','http://github.com/','https://example.org/','https://example.net/'])assert.deepEqual(eligibleEntries(url,entries),[],url);
 assert.deepEqual(eligibleEntries('https://xn--bcher-kva.example/',entries),['idn']);assert.deepEqual(eligibleEntries('https://bücher.example/',entries),['idn']);
 assert.deepEqual(eligibleEntries('https://github.com/',[{entryId:'a',domains:['github.com']},{entryId:'b',domains:['github.com']}]),['a','b'],'both shown, never merged');
 assert.deepEqual(eligibleEntries('https://github.com/',null),[]);assert.deepEqual(eligibleEntries('https://github.com/',[null,{entryId:1,domains:['github.com']},{entryId:'x',domains:'github.com'}]),[]);
});
test('content-script patterns are exact hosts only, deduplicated, bounded, invalid dropped',()=>{
 const p=matchPatterns(entries);assert.deepEqual(p.sort(),['https://accounts.example.com/*','https://github.com/*','https://xn--bcher-kva.example/*']);
 for(const x of p)assert.ok(!x.includes('*.')&&!x.startsWith('*')&&x.startsWith('https://'));
 assert.equal(matchPatterns(Array.from({length:50},(_,i)=>({entryId:'e'+i,domains:['h'+i+'.example.com']})),{max:10}).length,10);assert.deepEqual(matchPatterns(undefined),[]);
});
