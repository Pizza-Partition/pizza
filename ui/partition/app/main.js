// Entry point: choose the backend, then start the one application.
import { startApp } from './app.js';
import { PROTOCOL_VERSION, request } from './transport.js';

const demo = new URLSearchParams(location.search).get('demo') === '1';
document.body.dataset.mode = demo ? 'demo' : 'live';

let storage = null;
if (!demo) {
  try {
    storage = globalThis.localStorage;
  } catch (error) {
    console.warn('Session references cannot be stored in this window:', error);
  }
}
const backend = demo
  ? (await import('./demo-backend.js')).createDemoBackend(PROTOCOL_VERSION)
  : request;

await startApp({ request: backend, demo, storage, version: PROTOCOL_VERSION });
