import test from 'node:test';
import assert from 'node:assert/strict';
import { assertContract, checkSchema } from '../src/validate.js';
import { createBridge, sequence } from '../src/bridge.js';

test('one contract accepts both corpora and rejects version drift', () => {
  for (const corpus of ['app', 'maint']) {
    assertContract('Context', { corpus, version: 1, capabilities: ['events'] });
  }
  assert.throws(() => assertContract('Context', { corpus: 'maint', version: 2, capabilities: [] }));
  assert.throws(() =>
    assertContract('Context', { corpus: 'maint', version: 1, capabilities: [], secret: 'leak' }),
  );
  assert.throws(() => checkSchema({ type: 'string', format: 'unknown' }));
});

test('simulation contract excludes real disk operations and numeric u64 loss', () => {
  const steps = Array.from({ length: 20 }, (_, index) => ({
    id: index + 1,
    label: 'simulate',
    simulated: true,
  }));
  assertContract('Plan', { id: 'transition-1', version: 1, steps });
  assert.throws(() => assertContract('Plan', { id: '../blob', version: 1, steps }));
  assert.throws(() =>
    assertContract('Plan', { id: 'transition-1', version: 1, steps: steps.slice(1) }),
  );
  steps[0].simulated = false;
  assert.throws(() => assertContract('Plan', { id: 'transition-1', version: 1, steps }));
  assertContract('Event', {
    seq: '18446744073709551615',
    step_id: 1,
    phase: 'commit',
    message: '',
  });
  assert.throws(() =>
    assertContract('Event', { seq: 9007199254740993, step_id: 1, phase: 'commit', message: '' }),
  );
});

test('native bridge validates versions, replay order and decimal u64 sequences', async () => {
  const calls = [];
  const events = [{ seq: '9007199254740993', step_id: 1, phase: 'commit', message: 'done' }];
  const native = {
    async postMessage(raw) {
      const req = JSON.parse(raw);
      calls.push(req);
      return JSON.stringify({
        version: 1,
        result: req.method === 'subscribe' ? events : { status: 'ok' },
      });
    },
  };
  const bridge = createBridge(native);
  const seen = [];
  await bridge.subscribe((event) => seen.push(event.seq));
  bridge.deliver(events); // A retried native delivery is deduplicated.
  assert.deepEqual(seen, ['9007199254740993']);
  assert.equal(bridge.lastSequence, '9007199254740993');
  assert.deepEqual(calls[0], { version: 1, method: 'subscribe', after: '0' });
  assert.throws(() => bridge.deliver([...events, ...events]));
  assert.throws(() => sequence('18446744073709551616'));
  assert.throws(() => sequence('01'));
  await assert.rejects(bridge.request('unknown'));
  const incompatible = createBridge({
    async postMessage() {
      return '{"version":2,"result":null}';
    },
  });
  await assert.rejects(incompatible.request('health'), /version mismatch/u);
});

test('execution state distinguishes hangs and degradation from successful progress', () => {
  for (const status of [
    'running',
    'succeeded',
    'failed',
    'hung',
    'degraded',
    'interrupted',
    'view_only',
  ]) {
    assertContract('Execution', {
      status,
      step_id: 8,
      committed: 7,
      total: 20,
      message: 'diagnostic',
    });
  }
  assert.throws(() =>
    assertContract('Execution', {
      status: 'succeeded',
      step_id: 0,
      committed: 21,
      total: 20,
      message: '',
    }),
  );
  assert.throws(() =>
    assertContract('Execution', {
      status: 'retrying',
      step_id: 8,
      committed: 7,
      total: 20,
      message: '',
    }),
  );
});
