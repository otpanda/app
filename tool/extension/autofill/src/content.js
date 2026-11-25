// Content script (registered only for exact-host patterns). It asks for a code with an argument-free message; the service worker decides from the
// browser-provided sender URL. It never reads or sends the page URL itself, never stores a code, and fills only when a field is present.
import { findOtpTargets, fillTarget } from './fields.js';
let busy=false,lastCode='';
const visible=el=>{const r=el.getBoundingClientRect();return r.width>0&&r.height>0&&getComputedStyle(el).visibility!=='hidden';};
async function attempt(){
 if(busy)return;const targets=findOtpTargets(document,{visible});if(!targets.length)return;
 busy=true;
 try{const r=await chrome.runtime.sendMessage({type:'otpanda-fill-request'});
  if(r?.status==='ok'&&r.code!==lastCode){for(const g of targets)if(fillTarget(g,r.code)){lastCode=r.code;break;}}
 }catch{/* service worker asleep or extension reloaded: do nothing */}finally{busy=false;}
}
new MutationObserver(()=>attempt()).observe(document,{childList:true,subtree:true});
attempt();
