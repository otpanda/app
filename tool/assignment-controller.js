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
      if(!Array.isArray(action)||action.length!==16||action[0]!=='otpanda-assignment'||action[1]!==1||action[2]!==b.intentId||action[6]!==target.sourceId||action[7]!==target.eventId||action[8]!==s.entryId||action[13]!==s.activeRecipients||action[14]!==s.automationRecipients||action[15]!==true)throw Error('Assignment summary/action mismatch');
      if(attempt!==this.generation)return;
      this.pending=b;this.state='confirm';return Object.freeze({...s,proofRequired:b.proofRequired!==false});
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
        if(['assigned','not-assigned'].includes(result?.status)){this.state=result.status;this.pending=null;return this.state;}
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
        if(['assigned','not-assigned'].includes(result?.status)){this.state=result.status;this.pending=null;return this.state;}
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
