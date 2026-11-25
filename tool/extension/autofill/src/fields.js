// One-time-code field detection and filling. DOM-agnostic: works on any root with querySelectorAll and elements with getAttribute and dispatchEvent.
const NAME=/(^|[^a-z])(otp|totp|mfa|2fa|tfa|one[-_ ]?time|verification|verify|security[-_ ]?code|auth(?:entication)?[-_ ]?code|passcode|token)([^a-z]|$)/i;
const BAD=/(password|passwd|pwd|email|e-mail|user|login|phone|tel|search|card|cc-|postal|zip|coupon|promo|captcha)/i;
const TYPES=new Set(['text','tel','number','password','']);
const attr=(el,n)=>String(el.getAttribute?.(n)??'');
export function isOtpField(el,{visible=()=>true}={}){
 if(!el||String(el.tagName).toLowerCase()!=='input')return false;
 const type=attr(el,'type').toLowerCase();if(!TYPES.has(type)||el.disabled||el.readOnly||!visible(el))return false;
 const ac=attr(el,'autocomplete').toLowerCase();
 if(ac.split(/\s+/).includes('one-time-code'))return true;
 if(type==='password'||ac.includes('password')||ac.includes('username')||ac==='email')return false;
 const hint=[attr(el,'name'),attr(el,'id'),attr(el,'aria-label'),attr(el,'placeholder'),attr(el,'data-testid')].join(' ');
 const max=Number(attr(el,'maxlength')||0);
 if(BAD.test(hint)&&!NAME.test(hint))return false;
 if(BAD.test(hint.replace(NAME,' ')))return false;
 return NAME.test(hint)&&(max===0||(max>=4&&max<=10)||max===1);
}
// Returns groups of inputs to fill: either [singleInput] or several maxlength=1 inputs sharing a parent (split digit boxes).
export function findOtpTargets(root,opts={}){
 const inputs=[...root.querySelectorAll('input')].filter(el=>isOtpField(el,opts));
 const singles=inputs.filter(el=>attr(el,'maxlength')==='1');
 const groups=[],used=new Set();
 const byParent=new Map();for(const el of singles){const p=el.parentElement??el.parentNode??null;if(!byParent.has(p))byParent.set(p,[]);byParent.get(p).push(el);}
 for(const list of byParent.values())if(list.length>=4&&list.length<=10){groups.push(list);list.forEach(e=>used.add(e));}
 for(const el of inputs)if(!used.has(el)&&attr(el,'maxlength')!=='1')groups.push([el]);
 return groups;
}
export const validCode=c=>typeof c==='string'&&/^[A-Za-z0-9-]{4,32}$/.test(c);
export function fillTarget(group,code,{setter}={}){
 if(!validCode(code)||!group.length)return false;
 const set=(el,v)=>{(setter??((e,x)=>{const d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');d?.set?d.set.call(e,x):(e.value=x);}))(el,v);};
 const fire=el=>{for(const t of ['input','change'])el.dispatchEvent(new (el.ownerDocument?.defaultView?.Event??globalThis.Event)(t,{bubbles:true}));};
 if(group.length===1){const el=group[0],max=Number(attr(el,'maxlength')||0),v=max&&code.length>max?null:code;if(v===null)return false;set(el,v);fire(el);return true;}
 const digits=code.replace(/-/g,'');if(digits.length!==group.length)return false;
 group.forEach((el,i)=>{set(el,digits[i]);fire(el);});return true;
}
