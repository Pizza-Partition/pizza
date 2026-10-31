import {test} from 'node:test';
import assert from 'node:assert/strict';
import {ExecutionMonitor} from '../prototype/execution-client.js';
const id='a'.repeat(64);
const {contract}=await import(new URL('../../../zig-out/share/pizza/protocol/contract.js',import.meta.url));
const PROTOCOL_VERSION=contract['x-pizza'].version;
const run=(status='running',completed=0)=>({version:PROTOCOL_VERSION,id,status,completed,total:2});
function fixture(request){
  const updates=[],errors=[],scheduled=[];
  const monitor=new ExecutionMonitor({request,onUpdate:s=>updates.push(s),onDisconnected:(e,id)=>errors.push({e,id}),schedule:fn=>{scheduled.push(fn);return fn;},unschedule:()=>{}});
  return {monitor,updates,errors,scheduled};
}
test('default timers retain their browser-global receiver on load and polling',()=>{
  const original_schedule=globalThis.setTimeout, original_unschedule=globalThis.clearTimeout;
  const calls=[];
  try {
    globalThis.setTimeout=function(fn, delay){assert.equal(this,globalThis,'setTimeout receiver');calls.push(['schedule',delay]);return 42;};
    globalThis.clearTimeout=function(id){assert.equal(this,globalThis,'clearTimeout receiver');calls.push(['cancel',id]);};
    const monitor=new ExecutionMonitor({request:async()=>run(),onUpdate:()=>{},onDisconnected:()=>{}});
    monitor.stop(); // Called before rendering the disk inventory.
    monitor.watch(run());
    monitor.stop();
    assert.deepEqual(calls,[['cancel',undefined],['cancel',undefined],['schedule',800],['cancel',42]]);
  } finally {globalThis.setTimeout=original_schedule;globalThis.clearTimeout=original_unschedule;}
});
test('reconnect reads the existing session without initiating elevation',async()=>{
  const f=fixture(async(path,data)=>{assert.equal(path,'/api/status');assert.deepEqual(data,{session_id:id,elevated:false});return run('succeeded',2);});
  await f.monitor.resume(id);assert.equal(f.updates[0].status,'succeeded');assert.equal(f.scheduled.length,0);
});
test('a terminal record stops polling',async()=>{
  const f=fixture(async()=>run('cancelled',1));f.monitor.watch(run());assert.equal(f.scheduled.length,1);await f.scheduled[0]();assert.equal(f.updates.at(-1).completed,1);assert.equal(f.scheduled.length,1);
});
test('cancelling ignores an older status response arriving later',async()=>{
  let resolve;const older=new Promise(r=>resolve=r);
  const f=fixture(async path=>path==='/api/cancel'?run('cancelled',1):older);
  f.monitor.watch(run());const pending=f.monitor.refresh();await f.monitor.cancel();resolve(run('running'));await pending;assert.equal(f.updates.at(-1).status,'cancelled');
});
test('lost connection preserves session identity and permits explicit authorization',async()=>{
  let fail=true;
  const f=fixture(async(_,data)=>{if(fail)throw Error('disconnected');assert.equal(data.elevated,true);return run('partial',1);});
  await f.monitor.resume(id);assert.equal(f.errors[0].id,id);fail=false;await f.monitor.resume(id,true);assert.equal(f.updates.at(-1).status,'partial');
});
test('a mismatched session cannot replace the current report',async()=>{
  const f=fixture(async()=>({...run(),id:'b'.repeat(64)}));await f.monitor.resume(id);assert.equal(f.updates.length,0);assert.match(f.errors[0].e.message,/does not match/);
});
test('a lost start reply discovers the session only when its approved digest matches',async()=>{
  const f=fixture(async(_,data)=>{assert.equal(data.session_id,undefined);assert.equal(data.approved_digest,'approved');return {...run('succeeded',2),plan_digest:'approved'};});
  await f.monitor.resume(null,false,'approved');assert.equal(f.updates[0].id,id);
  const mismatch=fixture(async()=>({...run('succeeded'),plan_digest:'another plan'}));await mismatch.monitor.resume(null,false,'approved');assert.equal(mismatch.updates.length,0);assert.equal(mismatch.errors.length,1);
});
