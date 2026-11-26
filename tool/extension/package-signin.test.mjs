import test from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,cp,mkdir,readFile,writeFile,rm,readdir}from'node:fs/promises';import{execFileSync}from'node:child_process';import os from'node:os';import path from'node:path';import vm from'node:vm';
test('sign-in package ships the worker autofill modules, the classic bundle, a no-grant manifest and the popup permission script',async()=>{
 const temp=await mkdtemp(path.join(os.tmpdir(),'otpanda-pkg-signin-'));try{
  const ext=path.join(temp,'tool/extension');await mkdir(path.dirname(ext),{recursive:true});await cp(new URL('./',import.meta.url).pathname,ext,{recursive:true,filter:s=>!s.includes('/e2e')});
  await mkdir(path.join(temp,'build/web'),{recursive:true});
  for(const f of ['otty-favicon-v7-16.png','otty-favicon-v7-32.png','session-bootstrap.js','realtime-client.js','flutter_service_worker.js'])await writeFile(path.join(temp,'build/web',f),'synthetic');
  await writeFile(path.join(temp,'build/web/index.html'),'<html><head><link rel="manifest" href="manifest.json"></head><body><script src="realtime-client.js"></script><script src="session-bootstrap.js"></script><script src="flutter_bootstrap.js" async></script></body></html>');
  await writeFile(path.join(temp,'build/web/flutter_bootstrap.js'),'_flutter.loader.load({serviceWorkerSettings:{}});');
  execFileSync(process.execPath,[path.join(ext,'package.mjs')],{env:{...process.env,OTPANDA_EXTENSION_SIGNIN:'1',OTPANDA_EXTENSION_API:'https://api.example.test',OTPANDA_EXTENSION_WEB:'https://web.example.test/app'}});
  const out=path.join(temp,'build/extension-preview'),m=JSON.parse(await readFile(path.join(out,'manifest.json'),'utf8'));
  assert.deepEqual(m.permissions,['identity','storage','scripting']);assert.deepEqual(m.host_permissions,['https://api.example.test/*']);
  assert.deepEqual(m.optional_host_permissions,['https://*/*']);assert.ok(!m.content_scripts,'no static content script: registration happens only after a user grant');
  assert.match(m.content_security_policy.extension_pages,/connect-src 'self' https:\/\/api\.example\.test https:\/\/api\.2fa\.directory wss:\/\/api\.example\.test;/);
  for(const f of ['autofill/content.js','autofill-permission.js','autofill/src/background.js','autofill/src/wiring.js','autofill/src/code-source.js','autofill/src/domain-union.js','autofill/src/fill-request.js','autofill/src/match.js','background.js','extension-auth.mjs'])await readFile(path.join(out,f));
  const src=await readdir(path.join(out,'autofill/src'));assert.ok(!src.some(f=>f.startsWith('content')),'content sources are not shipped as modules');
  const {CONTENT_PATH}=await import('./autofill/src/background.js');assert.equal(CONTENT_PATH,'autofill/content.js');
  new vm.Script(await readFile(path.join(out,CONTENT_PATH),'utf8'));
  assert.match(await readFile(path.join(out,'index.html'),'utf8'),/<script src="extension-session.js"><\/script><script src="autofill-permission.js"><\/script><script src="flutter_bootstrap.js"/);
  const bg=await readFile(path.join(out,'background.js'),'utf8');for(const f of ['./autofill/src/background.js','./autofill/src/wiring.js'])assert.ok(bg.includes(f));
 }finally{await rm(temp,{recursive:true,force:true});}
});
