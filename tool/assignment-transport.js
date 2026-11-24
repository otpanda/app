/* Inactive factory. Caller supplies the session closure, never stored bearer. */
const API='https://otpanda-api.abrahammurciano.workers.dev';
export function assignmentTransport({access,generation,fetchImpl=fetch,credentials=globalThis.navigator?.credentials}){
  const encode=bytes=>btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
  const decode=value=>{if(typeof value!=='string'||!/^[A-Za-z0-9_-]{2,1366}$/.test(value))throw Error('Invalid credential options');return Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));};
  async function request(operation,body){
    const token=access(),attempt=generation();if(!token)throw Error('Sign in required');
    const payload=JSON.stringify(body);if(new TextEncoder().encode(payload).byteLength>32768)throw Error('Request too large');
    const r=await fetchImpl(API+'/v1/manage/assignment/'+operation,{method:'POST',credentials:'omit',cache:'no-store',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:payload});
    if(attempt!==generation())throw Error('Session changed');
    const reader=r.body?.getReader();if(!reader)throw Error('Readable response required');let size=0,text='';const decoder=new TextDecoder('utf-8',{fatal:true});
    try{for(;;){const{done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>32768)throw Error('Response too large');text+=decoder.decode(value,{stream:true});}text+=decoder.decode();}catch(e){try{await reader.cancel();}catch{}throw e;}finally{reader.releaseLock();}
    if(attempt!==generation())throw Error('Session changed');
    if(r.status!==200)throw Error('Assignment outcome unconfirmed');
    return JSON.parse(text);
  }
  return Object.freeze({
    begin:({sourceId,eventId,entryId})=>request('begin',{sourceId,eventId,entryId}),
    finish:({intentId,token,action,response})=>request('finish',{intentId,token,action,response}),
    status:({intentId})=>request('status',{intentId}),
    prove:async options=>{
      const o=options,attempt=generation();if(!access()||!o||Object.keys(o).some(k=>!['rpId','challenge','timeout','userVerification','allowCredentials','extensions'].includes(k))||o.rpId!=='otpanda.github.io'||o.userVerification!=='required'||o.timeout!==120000||typeof o.challenge!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(o.challenge)||!Array.isArray(o.allowCredentials)||!o.allowCredentials.length||o.allowCredentials.length>100||(o.extensions&&Object.keys(o.extensions).length))throw Error('Invalid passkey options');
      const allowed=o.allowCredentials.map(c=>{if(c.type!=='public-key'||Object.keys(c).some(k=>!['id','type','transports'].includes(k)))throw Error('Invalid credential');return{type:'public-key',id:decode(c.id)};});
      const c=await credentials.get({publicKey:{rpId:'otpanda.github.io',challenge:decode(o.challenge),userVerification:'required',timeout:120000,allowCredentials:allowed}});
      if(attempt!==generation()||!access())throw Error('Session changed');
      if(!c||c.type!=='public-key')throw Error('Passkey cancelled');
      return{id:c.id,rawId:encode(new Uint8Array(c.rawId)),type:c.type,clientExtensionResults:c.getClientExtensionResults(),response:{clientDataJSON:encode(new Uint8Array(c.response.clientDataJSON)),authenticatorData:encode(new Uint8Array(c.response.authenticatorData)),signature:encode(new Uint8Array(c.response.signature)),userHandle:c.response.userHandle?encode(new Uint8Array(c.response.userHandle)):null}};
    },
  });
}
