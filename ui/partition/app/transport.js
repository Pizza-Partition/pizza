import { CONTRACT } from './protocol/contract.js';
export const PROTOCOL_VERSION = CONTRACT['x-pizza'].version;
async function callNative(binding, ...args) {
  const deadline = Date.now() + 10000;
  // webui.js creates its bridge on DOMContentLoaded, which fires after module
  // scripts have started. Wait for the page to finish loading before giving up.
  while (
    !globalThis.webui &&
    globalThis.document &&
    document.readyState !== 'complete' &&
    Date.now() < deadline
  )
    await new Promise((r) => setTimeout(r, 25));
  const bridge = globalThis.webui;
  if (!bridge) throw Error('Open Pizza using pizza (`zig build run`).');
  while (!bridge.isConnected()) {
    if (Date.now() > deadline) throw Error('The desktop connection was not established.');
    await new Promise((r) => setTimeout(r, 25));
  }
  const result = JSON.parse(await bridge.call(binding, ...args));
  if (result.error) {
    const error = Error(result.message || result.error);
    error.code = result.error;
    throw error;
  }
  if (result.version !== undefined && result.version !== PROTOCOL_VERSION)
    throw Error('Incompatible Pizza protocol version.');
  return result;
}
export const nativeRequest = (request) => callNative('pizza_request', JSON.stringify(request));
export async function request({ action, ...data }) {
  if (action === 'plan')
    return callNative('pizza_plan', JSON.stringify({ version: PROTOCOL_VERSION, ...data }));
  if (action === 'session') return callNative('pizza_session');
  return nativeRequest({ version: PROTOCOL_VERSION, action, ...data });
}
