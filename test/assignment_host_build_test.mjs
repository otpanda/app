import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
test('normal generated web host loads assignment before session bootstrap',async()=>{
 const {bundleAssignment}=await import('../tool/build-assignment-host.mjs');
 const host=await bundleAssignment(),context={};vm.runInNewContext(host,context);
 assert.equal(typeof context.OTPandaAssignmentController,'function');assert.equal(typeof context.OTPandaAssignmentTransport,'function');
 const brand=fs.readFileSync('tool/brand_hosts.py','utf8');assert.ok(brand.indexOf('src="assignment-host.js"')<brand.indexOf('src="session-bootstrap.js"'));
 assert.match(fs.readFileSync('tool/bootstrap.sh','utf8'),/node tool\/build-assignment-host.mjs web\/assignment-host.js/);
});
