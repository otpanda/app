// Generates the SYNTHETIC export fixtures with the API's own seal code, so the Dart opener is pinned to the real wire.
// Run from an API checkout:  node gen_export_vector.mjs <path-to-api>/src > fixtures/export-scenario.json   (WEIRD=1 for export-unrepresentable.json)
// Only synthetic secrets and a throwaway client key. Never real user keys.
import {pathToFileURL} from 'node:url';
const src=process.argv[2];
const {sealExport,importClientEphemeral,sha256Hex}=await import(pathToFileURL(src+'/totp-export-seal.js'));
const hashText=async t=>sha256Hex(new TextEncoder().encode(t));
const pair=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},true,['deriveBits']);
const pubRaw=new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey));
const b64u=b=>Buffer.from(b).toString('base64url');
const pub=b64u(pubRaw),client=await importClientEphemeral(pub),eph=await sha256Hex(client.raw);
const owner='synthetic-owner',device='synthetic-device',generation=2;
const ents=[
 {entryId:'e1',version:'1'.repeat(64),label:'Alpha "q" é',account:process.env.WEIRD?'a:b':'a@example.test',issuer:'Iss',catalogId:null,algorithm:'SHA-1',digits:6,period:30,fill:11},
 {entryId:'e2',version:'2'.repeat(64),label:'Beta',account:null,issuer:null,catalogId:'beta.example',algorithm:'SHA-256',digits:7,period:45,fill:22},
 {entryId:'e3',version:'3'.repeat(64),label:'Gamma 日本 😀',account:'g',issuer:process.env.WEIRD?'G\u2028':'G',catalogId:null,algorithm:'SHA-512',digits:8,period:30,fill:33},
];
const actionDigest=await hashText(JSON.stringify(['totp-export-v1',owner,device,generation,ents.map(e=>[e.entryId,e.version]),eph]));
const items=ents.map(e=>({aad:{ownerId:owner,deviceId:device,generation,entryId:e.entryId,seedVersion:e.version,algorithm:e.algorithm,digits:e.digits,period:e.period,label:e.label,account:e.account,issuer:e.issuer,catalogId:e.catalogId},secret:new Uint8Array(20).fill(e.fill)}));
const sealed=await sealExport({client,actionDigest,ephemeralDigest:eph,items});
const jwk=await crypto.subtle.exportKey('jwk',pair.privateKey);
console.log(JSON.stringify({owner,device,generation,clientPublic:pub,clientScalar:jwk.d,actionDigest,
 begin:ents.map(({fill,algorithm,digits,period,...a})=>a),
 response:{serverPublicKey:sealed.serverPublicKey,entries:ents.map((e,i)=>({entryId:e.entryId,version:e.version,label:e.label,account:e.account,issuer:e.issuer,catalogId:e.catalogId,algorithm:e.algorithm,digits:e.digits,period:e.period,nonce:sealed.entries[i].nonce,ciphertext:sealed.entries[i].ciphertext}))},
 fills:ents.map(e=>e.fill)},null,1));
