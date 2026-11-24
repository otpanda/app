// Explicit inactive-host assembly only. The normal brand_hosts.py never calls it.
import {readFile,writeFile} from 'node:fs/promises';
export async function bundleAssignment(){
 const controller=await readFile(new URL('./assignment-controller.js',import.meta.url),'utf8');
 const transport=await readFile(new URL('./assignment-transport.js',import.meta.url),'utf8');
 return '(()=>{\n'+controller.replace('export class ','class ')+transport.replace('export function ','function ')+ '\nObject.defineProperties(globalThis,{OTPandaAssignmentController:{value:AssignmentController},OTPandaAssignmentTransport:{value:assignmentTransport}});\n})();\n';
}
if(process.argv[1]&&import.meta.url===new URL(process.argv[1],'file:').href){
 if(process.argv.length!==3)throw Error('Explicit output file required');
 await writeFile(process.argv[2],await bundleAssignment());
}
