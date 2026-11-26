const {chromium}=await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
import {readFile} from 'node:fs/promises';
import {generateKeyPairSync} from 'node:crypto';
import assert from 'node:assert/strict';
import {bundleAssignment} from './build-assignment-host.mjs';
const root=new URL('../',import.meta.url).pathname.replace(/\/$/,'');
const output=process.env.ASSIGNMENT_EVIDENCE_DIR || '/tmp';
const bundle=await bundleAssignment(),bootstrap=await readFile(root+'/tool/session-bootstrap.js','utf8');
const browser=await chromium.launch({headless:true});
try{for(const mode of ['assigned','unknown','not-assigned']){
 const context=await browser.newContext({viewport:{width:360,height:800}}),page=await context.newPage();let begins=0,finishes=0,statuses=0;const errors=[];page.on('pageerror',e=>errors.push(e.message));
 const cdp=await context.newCDPSession(page);await cdp.send('WebAuthn.enable');const {authenticatorId}=await cdp.send('WebAuthn.addVirtualAuthenticator',{options:{protocol:'ctap2',transport:'internal',hasResidentKey:true,hasUserVerification:true,isUserVerified:true,automaticPresenceSimulation:true}});
 const {privateKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});await cdp.send('WebAuthn.addCredential',{authenticatorId,credential:{credentialId:Buffer.from([1,2,3]).toString('base64'),isResidentCredential:false,rpId:'otpanda.github.io',privateKey:privateKey.export({format:'der',type:'pkcs8'}).toString('base64'),signCount:0}});
 await page.addInitScript(()=>{const state='s'.repeat(43);sessionStorage.setItem('otpanda.restore.tab.v1',JSON.stringify({state,verifier:'v'.repeat(43),created:Date.now()}));history.replaceState(null,'','/app/#code=otpda_'+'a'.repeat(55)+'&state='+state);});
 await page.route('https://otpanda.github.io/app/**',async route=>{let file=new URL(route.request().url()).pathname.slice(5)||'index.html';if(file==='session-bootstrap.js')return route.fulfill({contentType:'text/javascript',body:bundle+bootstrap});const ext=file.split('.').at(-1);await route.fulfill({path:root+'/build/web/'+file,contentType:({html:'text/html',js:'text/javascript',json:'application/json',wasm:'application/wasm'})[ext]});});
 await page.route('https://otpanda-api.abrahammurciano.workers.dev/**',async route=>{const u=route.request().url();const headers={'Access-Control-Allow-Origin':'https://otpanda.github.io','Access-Control-Allow-Headers':'Authorization, Content-Type','Access-Control-Allow-Methods':'POST, OPTIONS'};if(route.request().method()==='OPTIONS')return route.fulfill({status:204,headers});let body;
 if(u.endsWith('/auth/exchange'))body={access:'otpda_'+'a'.repeat(55),accessExpiresAt:Date.now()+900000};
 else if(u.endsWith('/begin')){begins++;body={intentId:'fixture-intent',token:'fixture-ceremony',action:JSON.stringify(['otpanda-assignment',1,'fixture-intent','owner','device',1,'fixture-source','fixture-event','fixture-entry',0,'hash',0,0,2,1,true]),expiresAt:Date.now()+120000,options:{rpId:'otpanda.github.io',challenge:'A'.repeat(43),timeout:120000,userVerification:'required',allowCredentials:[{type:'public-key',id:'AQID'}]},summary:{operation:'assign-code',entryId:'fixture-entry',label:'Northstar work',accountName:'work@example.test',serviceId:'fixture',activeRecipients:2,automationRecipients:1,irreversible:true}};}
 else if(u.endsWith('/finish')){finishes++;assert.equal(JSON.parse(route.request().postData()).response.type,'public-key');if(mode!=='assigned')return route.abort('failed');body={status:'assigned'};}
 else if(u.endsWith('/status')){statuses++;body={status:mode==='not-assigned'?'not-assigned':mode==='assigned'?'assigned':'expired'};}
 else throw Error('Unexpected '+u);
 await route.fulfill({status:200,headers,contentType:'application/json',body:JSON.stringify(body)});});
 await page.goto('https://otpanda.github.io/app/');await page.locator('flutter-view').waitFor();await page.locator('flt-semantics-placeholder').evaluate(e=>e.dispatchEvent(new Event('click')));
 await page.getByText('Active recipients: 2',{exact:true}).waitFor();assert.equal(finishes,0);assert.equal(begins,1);await page.screenshot({path:output+'/otpanda-assignment-confirm-360.png'});
 await page.getByRole('button',{name:'Confirm with passkey'}).click();await page.getByText(mode==='assigned'?'Assignment confirmed.':mode==='not-assigned'?/Server confirmed this assignment did not happen/:/It may have happened/).waitFor();
 assert.equal(finishes,1);assert.equal(statuses,mode==='assigned'?0:1);assert.deepEqual(errors,[]);assert.equal(await page.evaluate(()=>sessionStorage.getItem('otpanda.restore.tab.v1')),null);
 await page.screenshot({path:output+'/otpanda-assignment-'+mode+'-360.png'});console.log(JSON.stringify({mode,begins,finishes,statuses,errors,virtualWebAuthn:true}));await context.close();
 }}finally{await browser.close();}
