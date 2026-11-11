import test from 'node:test';
import assert from 'node:assert/strict';
import {GIB, displayName, displayGiB, formatBytes, inputGiB, parseGiB, regions, PlanClient} from '../app/plan-model.js';
const cap = ['resize','format','delete'].map(operation=>({operation,support:'offline_check'}));
test('decimal GiB input round-trips sector-aligned uint64 sizes without Number conversion',()=>{
  for(const sector of [512n,4096n]) for(const n of [sector,1073741824n,9007199254740992n,18446744073709547520n]) {
    const aligned=n/sector*sector;
    assert.equal(parseGiB(inputGiB(aligned),Number(sector)),aligned);
  }
  assert.throws(()=>parseGiB('1e10',512));assert.throws(()=>parseGiB('-1',512));
});
test('editor adapter serializes edits and forwards only backend-produced layouts',async()=>{
  const calls=[];
  const client=new PlanClient(async(req)=>{calls.push(req);if(req.command?.kind==='bad')throw Error('rejected');return {draft:{layout:[{id:String(calls.length)}]}};},{snapshot_id:'snapshot'},{identity:'disk'},true);
  const first=client.edit({kind:'add_left'}),second=client.edit({kind:'label'});
  await Promise.all([first,second]);
  assert.equal(calls[0].layout,undefined);
  assert.deepEqual(calls[1].layout,[{id:'1'}]);
  assert.equal(calls[1].elevated,true);
  await assert.rejects(client.edit({kind:'bad'}));
  await client.edit(undefined,{review:true});
  assert.deepEqual(calls[3].layout,[{id:'2'}]);
  assert.equal(calls[3].review,true);
});
test('free spans are produced only from verified usable bounds, not from filesystem free bytes',()=>{
  const disk={partitions:[{id:'a',offset:'4096',length:'4096',free_bytes:'4000'}]};
  assert.equal(regions(disk).length,1);
  const p=regions({...disk,usable_offset:'4096',usable_length:'16384'});
  assert.equal(p.length,2);assert.equal(p[1].length,12288n);assert.equal(p[1].offset,8192n);
  assert.equal(p[1].name,'');assert.equal(displayName(p[1]),'Free Space');
  assert.equal(p[0].name,undefined);assert.equal(displayName(p[0]),'Untitled partition');
});

test('visible GiB values have at most two decimals while canonical bytes stay exact',()=>{
  assert.equal(displayGiB(700721397760n),'652.6');
  assert.equal(formatBytes(700721397760n),'652.6 GiB');
  assert.equal(formatBytes(16759808n),'15.98 MiB');
  assert.equal(formatBytes(1536n),'1.5 KiB');
  assert.equal(displayGiB(1073741824n),'1');
  assert.equal(displayGiB(0n),'0');
  assert.equal(displayGiB(10737418240n),'10');
  assert.equal(displayGiB(2040109466n),'1.9');
  assert.match(displayGiB(9007199254740992n),/^\d+(\.\d{1,2})?$/);
});
