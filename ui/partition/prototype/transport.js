import {contract} from './protocol/contract.js';
export const PROTOCOL_VERSION=contract['x-pizza'].version;
async function callNative(binding, ...args) {
  const bridge=globalThis.webui;
  if (!bridge) throw Error('Open Pizza using pizza (`zig build run`).');
  const deadline=Date.now()+10000;
  while(!bridge.isConnected()) { if(Date.now()>deadline) throw Error('The desktop connection was not established.'); await new Promise(r=>setTimeout(r,25)); }
  const result=JSON.parse(await bridge.call(binding,...args));
  if(result.error) {const error=Error(result.message||result.error);error.code=result.error;throw error;}
  if(result.version!==undefined && result.version!==PROTOCOL_VERSION)throw Error('Incompatible Pizza protocol version.');
  return result;
}
export const nativeRequest = (request) => callNative('pizza_request',JSON.stringify(request));
export async function request(path,data) {
  if(path==='/api/plan')return callNative('pizza_plan',JSON.stringify({version:PROTOCOL_VERSION,...data}));
  if(path==='/api/session')return callNative('pizza_session');
  const segments=path.split('/'),elevated=segments.at(-1)==='elevated';
  const action=segments.at(elevated?-2:-1);
  const req={version:PROTOCOL_VERSION,action};
  if(action==='validate')req.draft=data;
  else if(['execute','prepare','reboot','complete'].includes(action))Object.assign(req,data);
  else if(action==='status'||action==='cancel')Object.assign(req,{session_id:data.session_id,elevated:!!data.elevated,approved_digest:data.approved_digest});
  if(elevated)req.elevated=true;
  return nativeRequest(req);
}
