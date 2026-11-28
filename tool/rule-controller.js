// All lasting-rule disclosures are derived from the canonical action, not summary prose.
const safe=(x,max=256)=>typeof x==='string'&&x.length>0&&x.length<=max&&!/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\u061c\ufeff]/u.test(x);
const count=x=>Number.isSafeInteger(x)&&x>=0;
export function validateRuleAction(b,target,{ownerId,deviceId,generation,now=Date.now()}={}){
 const s=b?.summary,a=JSON.parse(b?.action??'null');
 if(typeof b?.action!=='string'||new TextEncoder().encode(b.action).length>3072||!Array.isArray(a)||!((a[1]===5&&a.length===16)||(a[1]===6&&a.length===19))||a[0]!=='otpanda-rule'||!safe(a[2])||a[2]!==b.intentId||!safe(a[3])||!safe(a[4])||!count(a[5])||!count(a[9])||!/^([a-f0-9]{64})$/.test(a[10])||!count(a[12])||!count(a[13])||typeof a[14]!=='boolean'||a[14]!==(a[12]===0&&a[13]===0)||a[14]===b.proofRequired||typeof b.proofRequired!=='boolean')throw Error('Invalid rule action');
 if(ownerId!==undefined&&a[3]!==ownerId||deviceId!==undefined&&a[4]!==deviceId||generation!==undefined&&a[5]!==generation)throw Error('Rule identity mismatch');
 if(!['review','edit','resume'].includes(a[6])||a[6]!==target.operation||a[7]!==target[a[6]==='review'?'contextId':'ruleId']||a[8]!==target.entryId||!safe(a[7])||!safe(a[8]))throw Error('Rule target mismatch');
 if(!Number.isSafeInteger(b.expiresAt)||b.expiresAt<=now||b.expiresAt>now+120000||(a[6]==='review'?(!Number.isSafeInteger(a[11])||a[11]<b.expiresAt):a[11]!==null))throw Error('Expired rule action');
 const d=JSON.parse(a[15]),op=a[6];if(!Array.isArray(d))throw Error('Rule descriptor');
 let senderKind,sender,sourceId,serviceId,phrase,basis,otherAccountRules,addressScope,basisBefore,phraseBefore;
 if(op==='edit'){
  if(d.length!==10||d[0]!=='edit'||!['template','phrase'].includes(d[5])||!['template','phrase'].includes(d[7])||(d[5]==='template'?d[6]!==null:!safe(d[6],120))||(d[7]==='template'?d[8]!==null:!safe(d[8],120)))throw Error('Rule edit descriptor');
  [,senderKind,sender,sourceId,serviceId,basisBefore,phraseBefore,basis,phrase,otherAccountRules]=d;
  if(target.phrase!==phrase)throw Error('Rule phrase mismatch');
 }else{
  if(d.length!==9||d[0]!== (op==='review'?'save':'resume')||(d[3]!==null&&!safe(d[3])))throw Error('Rule descriptor');
  [,senderKind,sender,,sourceId,serviceId]=d;
  if(op==='review'){
   phrase=d[6];if(typeof d[7]!=='boolean'||(d[7]?phrase!==null:!safe(phrase,120)))throw Error('Rule basis');basis=d[7]?'template':'phrase';
   if((target.phrase??null)!==phrase)throw Error('Rule phrase mismatch');
  }else{basis=d[6];phrase=d[7];if(!['template','phrase'].includes(basis)||(basis==='template'?phrase!==null:!safe(phrase,120)))throw Error('Resume basis');}
  otherAccountRules=d[8];addressScope=d[3]===null?'any-address-on-connector':'receiving-address';
 }
 if(!['email_address','sms_number'].includes(senderKind)||!safe(sender)||!safe(sourceId)||!safe(serviceId)||!count(otherAccountRules))throw Error('Rule scope');
 const operation=op==='review'?'rule-from-review':op==='edit'?'rule-edit':'rule-resume';
 const derived={operation,entryId:a[8],sender,senderKind,sourceId,serviceId,basis,phrase,futureRecipients:a[12],futureAutomations:a[13],otherAccountRules,irreversible:false,...(op==='edit'?{basisBefore,phraseBefore,mayMatchOtherTemplates:true}:{addressScope,...(op==='review'?{previewRemoved:true}:{resumesPausedRule:true})})};
 if(!s||Object.entries(derived).some(([k,v])=>k!=='sourceId'&&s[k]!==v)||!safe(s.label,64)||(s.accountName!==null&&s.accountName!==''&&!safe(s.accountName,128)))throw Error('Rule disclosure mismatch');
 if(a[1]===6&&(a[16]!==s.label||a[17]!==(s.accountName??'')||a[18]!==serviceId))throw Error('Native rule label mismatch');
 return Object.freeze({...derived,label:a[1]===6?a[16]:s.label,accountName:a[1]===6?a[17]:s.accountName,proofRequired:b.proofRequired});
}
export class RuleController{
 constructor({begin,prove,finish,status,now=Date.now}){Object.assign(this,{begin,prove,finish,status,now});this.state='idle';this.pending=null;this.busy=false;this.generation=0;this.result=null;}
 async prepare(target){
  if(this.busy||this.pending)throw Error('Review the current rule outcome first');this.busy=true;const attempt=this.generation;
  try{const b=await this.begin(target);const s=validateRuleAction(b,target,{now:this.now()});if(JSON.parse(b.action)[1]!==5)throw Error('Web rule version');if(b.proofRequired?(typeof b.token!=='string'||!b.options):b.token!==undefined||b.options!==undefined||b.challenge!==undefined)throw Error('Rule proof mismatch');if(attempt!==this.generation)throw Error('Session changed');this.pending=b;this.result=null;this.state='confirm';return s;}catch(e){if(attempt===this.generation)this.state='unavailable';throw e;}finally{if(attempt===this.generation)this.busy=false;}
 }
 accept(r){if(r?.status==='not-applied'){this.state='not-applied';this.pending=null;this.result=null;return true;}if(r?.status==='applied'&&['saved','exists','updated','unavailable','resumed','paused'].includes(r.rule?.status)){this.result=r.rule;this.state=r.rule.status==='paused'?'paused':r.rule.status==='unavailable'?'applied-unavailable':'applied';this.pending=null;return true;}return false;}
 async confirm(){
  if(this.busy||this.state!=='confirm'||!this.pending)throw Error('No rule to confirm');const b=this.pending,attempt=this.generation;if(this.now()>=b.expiresAt){this.state='expired';this.pending=null;return this.state;}this.busy=true;this.state='authenticating';let response;
  try{response=b.proofRequired?await this.prove(b.options):undefined;}catch{if(attempt===this.generation){this.state='cancelled';this.busy=false;this.pending=null;}return this.state;}
  if(attempt!==this.generation)return this.state;this.state='submitting';
  try{const r=await this.finish({intentId:b.intentId,action:b.action,...(b.proofRequired?{token:b.token,response}:{})});if(attempt!==this.generation)return this.state;if(this.accept(r))return this.state;}catch{}finally{if(attempt===this.generation)this.busy=false;}
  if(attempt!==this.generation)return this.state;this.state='unknown';return this.reconcile();
 }
 async reconcile(){if(this.busy||!this.pending||!['unknown','pending'].includes(this.state))return this.state;const attempt=this.generation,id=this.pending.intentId;this.busy=true;try{const r=await this.status({intentId:id});if(attempt!==this.generation)return this.state;if(!this.accept(r))this.state=r?.status==='pending'?'pending':'unknown';}catch{if(attempt===this.generation)this.state='unknown';}finally{if(attempt===this.generation)this.busy=false;}return this.state;}
 clear(){this.generation++;this.pending=null;this.busy=false;this.state='idle';this.result=null;}
 dismiss(){if(this.busy||['unknown','pending','submitting'].includes(this.state))throw Error('Rule outcome unconfirmed');this.pending=null;this.state='idle';this.result=null;}
}
