import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const contract=new URL('../../../zig-out/share/pizza/protocol/contract.js',import.meta.url).href;
const source=(await readFile(new URL('../app/transport.js',import.meta.url),'utf8')).replace('./protocol/contract.js',contract);
const {request,PROTOCOL_VERSION}=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
test('native session advertises actual readiness and validation keeps administrator scope',async()=>{
  const calls=[];
  const bridge={isConnected(){assert.equal(this,bridge);return true;},async call(binding,payload){assert.equal(this,bridge);calls.push([binding,payload&&JSON.parse(payload)]);return JSON.stringify(binding==='pizza_session'?{version:PROTOCOL_VERSION,writes_enabled:false,execution_issue:'pkexec is missing'}:{version:PROTOCOL_VERSION});}};
  globalThis.webui=bridge;
  try {
    assert.equal((await request('/api/session')).writes_enabled,false);
    const draft={snapshot_id:'root snapshot',layout:[]};
    await request('/api/validate/elevated',draft);
    assert.deepEqual(calls[1],['pizza_request',{version:PROTOCOL_VERSION,action:'validate',draft,elevated:true}]);
    await request('/api/inventory/elevated',{});
    assert.deepEqual(calls[2],['pizza_request',{version:PROTOCOL_VERSION,action:'inventory',elevated:true}]);
    const prepared={draft,approved_digest:'approved'};
    await request('/api/prepare',prepared);
    assert.deepEqual(calls[3],['pizza_request',{version:PROTOCOL_VERSION,action:'prepare',...prepared}]);
    const restart={session_id:'session',approved_digest:'approved'};
    await request('/api/reboot',restart);
    assert.deepEqual(calls[4],['pizza_request',{version:PROTOCOL_VERSION,action:'reboot',...restart}]);
    await request('/api/complete',{session_id:'session'});
    assert.deepEqual(calls[5],['pizza_request',{version:PROTOCOL_VERSION,action:'complete',session_id:'session'}]);
    const edit={snapshot_id:'snapshot',disk_identity:'disk',command:{kind:'add_left',partition_id:'free:0',filesystem:'ntfs'},review:true};
    await request('/api/plan',edit);
    assert.deepEqual(calls[6],['pizza_plan',{version:PROTOCOL_VERSION,...edit}]);
    await request('/api/discover');
    assert.deepEqual(calls[7], ['pizza_request', {version:PROTOCOL_VERSION,action:'discover'}]);
    await request('/api/discover/elevated');
    assert.deepEqual(calls[8], ['pizza_request', {version:PROTOCOL_VERSION,action:'discover',elevated:true}]);
  } finally {delete globalThis.webui;}
});
test('live requests require the WebUI bridge',async()=>{
  await assert.rejects(request('/api/session'),/Open Pizza using pizza/);
  await assert.rejects(request('/api/inventory'),/Open Pizza using pizza/);
});
