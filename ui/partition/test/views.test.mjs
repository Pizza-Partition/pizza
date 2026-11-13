import test from 'node:test';
import assert from 'node:assert/strict';
import { plan } from '../app/views.js';

function fixture() {
  const part = {
    id: 'data',
    offset: 1048576n,
    length: 1072693248n,
    name: 'Data <unsafe>',
    filesystem: 'ext4',
    retain_data: true,
    encryption: 'none',
    capabilities: [{ operation: 'resize', support: 'available' }],
  };
  const disk = {
    identity: 'disk',
    path: '/fixture',
    model: 'fixture',
    capacity: '1073741824',
    sector_size: 512,
    partition_table: 'gpt',
    usable_offset: '1048576',
    usable_length: '1072693248',
    partitions: [part],
  };
  return {
    inventory: { disks: [disk] },
    disk,
    parts: [part],
    baseline: [part],
    selected: part.id,
    editable: true,
    session: { writes_enabled: true },
    formats: [],
    unit: 'GiB',
    intents: [],
    canUndo: false,
  };
}

test('the final resize-capable partition can shrink without a right neighbor', () => {
  const state = fixture();
  assert.doesNotMatch(plan(state).inspector, /id="size-value"[^>]* disabled/);
  state.parts[0].encryption = 'unknown';
  assert.match(plan(state).inspector, /id="size-value"[^>]* disabled/);
});

test('the partition table preserves exact sizes and escapes labels', () => {
  const state = fixture();
  const view = plan(state);
  assert.match(view.table, /Data &lt;unsafe&gt;/);
  assert.doesNotMatch(view.table, /Data <unsafe>/);
  assert.match(view.table, /data-select="data"/);
  assert.match(view.navigation, /aria-current="true"/);
});

test('the pizza keeps the planned proportions and refreshes accessible partition names', () => {
  const state = fixture();
  const initial = plan(state).pizza;
  assert.match(initial, /class="partition-pizza"/);
  assert.match(initial, /class="pizza-svg/);
  assert.match(initial, /aria-label="Planned partitions, to scale: Data &lt;unsafe&gt;"/);
  assert.equal(plan(state).pizza, initial, 'unchanged artwork reuses the same SVG resources');
  state.parts = [{ ...state.parts[0], name: 'Renamed' }];
  assert.match(plan(state).pizza, /to scale: Renamed/);
  state.parts = [
    { ...state.parts[0], name: 'Renamed', length: 536870912n },
    {
      id: 'free',
      length: 535822336n,
      free: true,
    },
  ];
  const changed = plan(state).pizza;
  assert.match(changed, /to scale: Renamed, Free Space/);
  assert.equal((changed.match(/class="pizza-slice /g) ?? []).length, 2);
  assert.doesNotMatch(changed, /Data &lt;unsafe&gt;/);
});

test('rename changes identify the original partition and the approved new name', () => {
  const state = fixture();
  state.parts = [{ ...state.parts[0], name: 'Renamed' }];
  state.intents = [{ kind: 'label', partition_id: 'data', label: 'Renamed' }];
  assert.match(plan(state).changes, /Rename Data &lt;unsafe&gt;/);
  assert.match(plan(state).changes, /To “Renamed”/);
});
