import {readFile,writeFile,mkdir,cp,rm,readdir,lstat,access,rename,mkdtemp} from 'node:fs/promises';
import path from 'node:path';
// Package only a previously built fictional preview. This never enables auth.
const root=path.resolve(import.meta.dirname,'../..');
const build=path.join(root,'build/web');
const destination=path.resolve(process.argv[2]??path.join(root,'build/extension-preview'));
const canonicalRoot=await import('node:fs/promises').then(fs=>fs.realpath(root));
const canonicalBuild=await import('node:fs/promises').then(fs=>fs.realpath(path.join(root,'build')));
if(canonicalBuild!==path.join(canonicalRoot,'build'))throw Error('Refusing symlinked build directory');
if(path.dirname(destination)!==path.join(root,'build')||!path.basename(destination).startsWith('extension-'))throw Error('Output must be build/extension-* in this checkout');
async function rejectLinks(dir){for(const item of await readdir(dir,{withFileTypes:true})){const file=path.join(dir,item.name);if((await lstat(file)).isSymbolicLink())throw Error('Source symlinks are not allowed');if(item.isDirectory())await rejectLinks(file);}}
if((await lstat(build)).isSymbolicLink())throw Error('Source symlinks are not allowed');await rejectLinks(build);
const source=await readFile(path.join(build,'index.html'),'utf8');
if(!source.includes('session-bootstrap.js'))throw Error('Expected reviewed web preview bootstrap');
const out=await mkdtemp(path.join(root,'build/.extension-stage-'));try{await cp(build,out,{recursive:true});
// Extension sign-in is intentionally unsupported. No web cookie/session bridge.
let html=source.replace('<script src="session-bootstrap.js"></script>','').replace('<script src="realtime-client.js"></script>','').replace(/<link rel="manifest"[^>]*>/,'');
html=html.replace('<script src="flutter_bootstrap.js"', '<script src="extension-session.js"></script><script src="flutter_bootstrap.js"');
html=html.replace('</head>','<link rel="stylesheet" href="extension-host.css"></head>');
if(!html.includes('<script src="extension-session.js"></script><script src="flutter_bootstrap.js"'))throw Error('Unsupported bridge injection failed');
if(html.includes('session-bootstrap')||html.includes('realtime-client'))throw Error('Web session removal failed');
await writeFile(path.join(out,'index.html'),html);
await writeFile(path.join(out,'extension-session.js'),"'use strict';const unsupported=async()=>({status:503,body:JSON.stringify({error:'unsupported'})});Object.defineProperty(globalThis,'OTPandaSession',{value:Object.freeze({ready:Promise.resolve(),status:()=> 'unsupported',start:async()=>{throw Error('unsupported')},passkey:async()=>{throw Error('unsupported')},clear:()=>{},logout:()=>{},read:unsupported,organize:unsupported,copied:unsupported}),writable:false,configurable:false});\n");
await rm(path.join(out,'session-bootstrap.js'),{force:true});
await rm(path.join(out,'realtime-client.js'),{force:true});
await rm(path.join(out,'flutter_service_worker.js'),{force:true});
let bootstrap=await readFile(path.join(out,'flutter_bootstrap.js'),'utf8');
bootstrap=bootstrap.replace(/_flutter\.loader\.load\(\{[\s\S]*?\}\);\s*$/,'_flutter.loader.load({});');
if(!bootstrap.endsWith('_flutter.loader.load({});')||/serviceWorker/.test(bootstrap.slice(bootstrap.lastIndexOf('_flutter.loader.load('))))throw Error('Service worker configuration removal failed');
await writeFile(path.join(out,'flutter_bootstrap.js'),bootstrap);
for(const icon of ['otty-favicon-v2-16.png','otty-favicon-v2-32.png'])await access(path.join(out,icon));
await writeFile(path.join(out,'extension-host.css'),'html,body{width:390px;height:600px;min-width:390px;min-height:600px;margin:0;overflow:hidden}\n');
await writeFile(path.join(out,'manifest.json'),JSON.stringify({manifest_version:3,name:'OTPanda shared UI preview',version:'0.0.1',description:'Local fictional Flutter preview. Sign-in and browser-page access are not connected.',action:{default_popup:'index.html',default_title:'OTPanda preview'},icons:{16:'otty-favicon-v2-16.png',32:'otty-favicon-v2-32.png'},content_security_policy:{extension_pages:"default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; object-src 'none'; connect-src 'self'; base-uri 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; frame-src 'none'; worker-src 'self'"}},null,2)+'\n');
await rm(destination,{recursive:true,force:true});await rename(out,destination);
console.log('Packaged fictional extension preview: '+destination);
}finally{await rm(out,{recursive:true,force:true});}
