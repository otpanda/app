// The rule descriptor is inside the signed action. Summary metadata may not expand it.
export function checkedAssignmentRule(action, summary, target) {
  const version=action[1],hasRule=version===3;
  if(!hasRule){if(summary.rule!==undefined)throw Error('Unsigned rule');return undefined;}
  const d=JSON.parse(action[16]),r=summary.rule;
  if(!Array.isArray(d)||!r||typeof r!=='object')throw Error('Invalid signed rule');
  if(d[0]==='none'){
    if(d.length!==2||typeof d[1]!=='string'||r.status!=='unavailable'||r.reason!==d[1])throw Error('Rule mismatch');
    return {status:'unavailable',reason:d[1]};
  }
  const safe=x=>typeof x==='string'&&x.length>0&&x.length<=256&&!/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\u061c\ufeff]/u.test(x);
  if(d.length!==8||d[0]!=='save'||!['sms_number','email_address'].includes(d[1])||!safe(d[2])||(d[3]!==null&&!safe(d[3]))||d[4]!==target.sourceId||d[5]!==summary.serviceId||!safe(d[5])||((d[6]===null)===(d[7]===null))||(d[6]!==null&&!safe(d[6]))||(d[7]!==null&&(typeof d[7]!=='string'||!/^v1:[a-f0-9]{64}$/.test(d[7]))))throw Error('Invalid signed rule');
  const basis=d[6]===null?'template':'phrase';
  if(!['will_save','already_saved_paused'].includes(r.status)||r.senderKind!==d[1]||r.sender!==d[2]||r.phrase!==d[6]||r.basis!==basis||r.futureRecipients!==action[13]||r.futureAutomations!==action[14])throw Error('Rule disclosure mismatch');
  if(r.status==='already_saved_paused'&&(!safe(r.ruleId)||r.resumeRequiresSignedAction!==true))throw Error('Invalid paused rule');
  return {status:r.status,...(r.status==='already_saved_paused'?{ruleId:r.ruleId,resumeRequiresSignedAction:true}:{}),senderKind:d[1],sender:d[2],phrase:d[6],basis,futureRecipients:action[13],futureAutomations:action[14]};
}
/* Unmounted controller. Ceremony data stays in memory, never persisted. */
export class AssignmentController {
  constructor({begin,prove,finish,status,now=Date.now,delay=ms=>new Promise(r=>setTimeout(r,ms))}) {
    Object.assign(this,{begin,prove,finish,status,now,delay});this.state='idle';this.pending=null;this.busy=false;this.generation=0;
  }
  async prepare(target){
    if(this.busy||this.pending)throw Error('Reconcile or dismiss the current action first');
    this.busy=true;const attempt=this.generation;
    try{
      const b=await this.begin(target),s=b?.summary;
      if(!b||typeof b.intentId!=='string'||!b.intentId||(b.proofRequired===false?(b.token!==undefined||b.options!==undefined||!s||s.activeRecipients!==0||s.automationRecipients!==0):typeof b.token!=='string')||typeof b.action!=='string'||!Number.isSafeInteger(b.expiresAt)||b.expiresAt<=this.now()||b.expiresAt>this.now()+120000||s?.operation!=='assign-code'||s.entryId!==target.entryId||typeof s.label!=='string'||(s.accountName!==null&&typeof s.accountName!=='string')||typeof s.serviceId!=='string'||!Number.isSafeInteger(s.activeRecipients)||s.activeRecipients<0||!Number.isSafeInteger(s.automationRecipients)||s.automationRecipients<0||s.irreversible!==true)throw Error('Invalid assignment summary');
      const action=JSON.parse(b.action);
      if(!Array.isArray(action)||!((action[1]===1&&action.length===16)||(action[1]===3&&action.length===17))||action[0]!=='otpanda-assignment'||action[2]!==b.intentId||action[6]!==target.sourceId||action[7]!==target.eventId||action[8]!==s.entryId||action[13]!==s.activeRecipients||action[14]!==s.automationRecipients||action[15]!==true)throw Error('Assignment summary/action mismatch');
      const rule=checkedAssignmentRule(action,s,target);
      if(attempt!==this.generation)return;
      this.pending=b;this.state='confirm';return Object.freeze({...s,...(rule?{rule}:{}),proofRequired:b.proofRequired!==false});
    }catch(e){if(attempt===this.generation)this.state='unavailable';throw e;}finally{if(attempt===this.generation)this.busy=false;}
  }
  // Must be called by a deliberate user gesture after showing the summary.
  async confirm(){
    if(this.busy||this.state!=='confirm'||!this.pending)throw Error('Confirmation unavailable');
    const b=this.pending;if(this.now()>=b.expiresAt){this.state='expired';return this.state;}
    this.busy=true;this.state='authenticating';const attempt=this.generation;let response;
    try{response=b.proofRequired===false?undefined:await this.prove(b.options);}catch{if(attempt!==this.generation)return this.state;this.state='cancelled';this.pending=null;this.busy=false;return this.state;}
    if(attempt!==this.generation)return this.state;
    this.state='submitting';
    try{
      const result=await this.finish(b.proofRequired===false?{intentId:b.intentId,action:b.action}:{intentId:b.intentId,token:b.token,action:b.action,response});
      if(attempt!==this.generation)return this.state;
        if(['assigned','not-assigned'].includes(result?.status)){this.state=result.status==='assigned'&&result.rule?.status==='paused'?'assigned-paused':result.status==='assigned'&&result.rule?.status==='unavailable'?'assigned-no-rule':result.status;this.pending=null;return this.state;}
    }catch{}
    finally{if(attempt===this.generation)this.busy=false;}
    if(attempt!==this.generation)return this.state;
    // Refusal/timeout is never proof that no write happened. No mutation retry.
    this.state='unknown';return this.reconcile();
  }
  async reconcile(){
    if(this.busy||!this.pending||!['unknown','pending'].includes(this.state))return this.state;
    this.busy=true;const id=this.pending.intentId,attempt=this.generation;
    try{
      for(const wait of [0,500,1500,3000]){
        if(wait)await this.delay(wait);
        if(attempt!==this.generation)return this.state;
        let result;try{result=await this.status({intentId:id});}catch{if(attempt===this.generation)this.state='unknown';return this.state;}
        if(attempt!==this.generation)return this.state;
        if(['assigned','not-assigned'].includes(result?.status)){this.state=result.status==='assigned'&&result.rule?.status==='paused'?'assigned-paused':result.status==='assigned'&&result.rule?.status==='unavailable'?'assigned-no-rule':result.status;this.pending=null;return this.state;}
        if(result?.status!=='pending'){this.state='unknown';return this.state;}
        this.state='pending';
      }
      return this.state;
    }finally{if(attempt===this.generation)this.busy=false;}
  }
  // Call on logout/disposal. This suppresses late UI outcomes, not a sent write.
  clear(){this.generation++;this.pending=null;this.busy=false;this.state='idle';}
  dismiss(){if(this.busy||['unknown','pending','submitting'].includes(this.state))throw Error('Outcome still needs review');this.pending=null;this.state='idle';}
}
