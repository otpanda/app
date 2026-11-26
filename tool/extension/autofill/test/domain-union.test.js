import test from 'node:test';
import assert from 'node:assert/strict';
import {buildCatalogIndex,entryDomains,autofillEntries,associationsFromResponse,LIMITS} from '../src/domain-union.js';
import {eligibleEntries,matchPatterns} from '../src/match.js';
const rows=[
 {n:'GitHub',d:['github.com'],i:'github.com.svg'},
 {n:'Amazon',d:['amazon.com','amazon.co.uk','amazon.de'],i:'amazon.com.svg'},
 {n:'Dup A',d:['dup.example'],i:'a.svg'},{n:'Dup B',d:['dup.example','b.dup.example'],i:'b.svg'},
 {n:'Bad extra',d:['good.example','*.evil.example'],i:'c.svg'},
 {n:'IDN',d:['bücher.example'],i:'d.svg'},
];
const index=buildCatalogIndex(rows);
test('catalogue domains: exact primary lookup returns primary plus additional, in canonical form',()=>{
 assert.deepEqual(entryDomains('github.com',[],index),['github.com']);
 assert.deepEqual(entryDomains('amazon.com',[],index),['amazon.co.uk','amazon.com','amazon.de']);
 assert.deepEqual(entryDomains('xn--bcher-kva.example',[],index),['xn--bcher-kva.example']);
});
test('no fuzzy or derived catalogue identity: additional domain, name, case, subdomain and unknown ids give nothing',()=>{
 for(const id of ['amazon.co.uk','GitHub','Github.com','github','www.github.com','github.com.evil.example','','x',null,undefined,5,'gi thub.com',{},['github.com']])assert.deepEqual(entryDomains(id,[],index),[],String(id));
});
test('shared primary and rows with an invalid listed domain contribute nothing',()=>{
 assert.deepEqual(entryDomains('dup.example',[],index),[]);
 assert.deepEqual(entryDomains('good.example',[],index),[]);
 assert.deepEqual(buildCatalogIndex(null).size,0);assert.deepEqual(entryDomains('github.com',[],null),[]);assert.deepEqual(entryDomains('github.com',[],new Map()),[]);
});
test('union with the viewer\'s own associations: deduplicated, normalized, invalid and wildcard dropped, bounded',()=>{
 assert.deepEqual(entryDomains('github.com',['GitHub.com','git.example.org','*.example.com','https://x.example','a.example/path','localhost','1.2.3.4',''],index),['git.example.org','github.com']);
 assert.deepEqual(entryDomains(undefined,['my.corp.example'],index),['my.corp.example']);
 const many=Array.from({length:50},(_,i)=>'h'+i+'.example.com');
 assert.equal(entryDomains(undefined,many,index).length,LIMITS.associationsPerEntry);
 assert.deepEqual(entryDomains(undefined,'not-an-array',index),[]);
});
test('associations come only from the viewer store, never from fields on the entry',()=>{
 const entries=[{entryId:'e1',catalogId:'github.com',associations:['evil.example'],domains:['evil.example'],ownerAssociations:['evil.example'],websiteHost:'evil.example'},{entryId:'e2'}];
 assert.deepEqual(autofillEntries(entries,index,{}),[{entryId:'e1',domains:['github.com']}]);
 assert.deepEqual(autofillEntries(entries,index,new Map([['e1',['work.example.com']],['e2',['x.example.com']]])),[{entryId:'e1',domains:['github.com','work.example.com']},{entryId:'e2',domains:['x.example.com']}]);
 assert.deepEqual(autofillEntries(entries,index,{e9:['other.example.com']}),[{entryId:'e1',domains:['github.com']}]);
});
test('entries are bounded and deduplicated; malformed input is ignored',()=>{
 assert.deepEqual(autofillEntries(null,index,{}),[]);
 assert.deepEqual(autofillEntries([null,{entryId:1},{entryId:''},{entryId:'a',catalogId:'github.com'},{entryId:'a',catalogId:'amazon.com'}],index,undefined),[{entryId:'a',domains:['github.com']}]);
});
test('end to end with match.js: exact listed and own domains match; parents, subdomains and the display name do not',()=>{
 const list=autofillEntries([{entryId:'gh',catalogId:'github.com'},{entryId:'amz',catalogId:'amazon.com'},{entryId:'mine',catalogId:'github.com'}],index,{mine:['sso.corp.example']});
 assert.deepEqual(eligibleEntries('https://github.com/session',list),['gh','mine']);
 assert.deepEqual(eligibleEntries('https://amazon.de/ap/signin',list),['amz']);
 assert.deepEqual(eligibleEntries('https://sso.corp.example/',list),['mine']);
 for(const u of ['https://www.github.com/','https://gist.github.com/','https://corp.example/','https://login.sso.corp.example/','https://www.amazon.com/','https://amazon.fr/','http://github.com/'])assert.deepEqual(eligibleEntries(u,list),[],u);
 assert.deepEqual(matchPatterns(list).sort(),['https://amazon.co.uk/*','https://amazon.com/*','https://amazon.de/*','https://github.com/*','https://sso.corp.example/*']);
});

test('API adapter: the real /v1/manage/entry/domains shape becomes the viewer association map',()=>{
 const body=JSON.stringify({associations:[{entryId:'e1',domains:['sso.corp.example.com','my.nas.local']},{entryId:'e2',domains:[]},{entryId:'bad id',domains:['x.example.com']},{entryId:'e1',domains:['dup.example.com']}]});
 const m=associationsFromResponse({status:200,body});
 assert.deepEqual([...m],[['e1',['sso.corp.example.com']],['e2',[]]]);
 const entries=[{entryId:'e1',catalogId:'github.com'},{entryId:'e2'}];
 assert.deepEqual(autofillEntries(entries,index,m),[{entryId:'e1',domains:['github.com','sso.corp.example.com']}]);
 assert.equal(associationsFromResponse({associations:[]}).size,0);
});
test('API adapter fails closed: non-200, bad JSON, extra members, wrong types and oversize give no associations',()=>{
 const good={associations:[{entryId:'e1',domains:['a.example.com']}]};
 for(const r of [{status:401,body:JSON.stringify(good)},{status:200,body:'not json'},{status:200,body:JSON.stringify({...good,merged:[]})},{status:200,body:JSON.stringify([good])},{status:200,body:JSON.stringify({associations:'x'})},{status:200,body:5},{status:200,body:JSON.stringify({associations:Array.from({length:1001},(_,i)=>({entryId:'e'+i,domains:[]}))})},null,undefined,5,'x'])assert.equal(associationsFromResponse(r),undefined,JSON.stringify(r));
 assert.deepEqual(autofillEntries([{entryId:'e1',catalogId:'github.com'}],index,undefined),[{entryId:'e1',domains:['github.com']}]);
 assert.deepEqual([...associationsFromResponse({status:200,body:JSON.stringify({associations:[{entryId:'e1',domains:Array.from({length:33},(_,i)=>'h'+i+'.example.com')},{entryId:'e2',domains:'x.example.com'}]})})],[]);
});
