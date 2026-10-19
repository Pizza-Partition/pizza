import { api } from './generated/contract.js';
import { assertContract } from './validate.js';

const maxSeq = 18446744073709551615n;
export function sequence(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,19})$/u.test(value) || BigInt(value) > maxSeq)
    throw new Error('Invalid journal sequence');
  return BigInt(value);
}

export function createBridge(native = globalThis.webkit?.messageHandlers?.[api.bridge_channel]) {
  if (!native) throw new Error('当前页面需要在 Pizza 内嵌界面中运行');
  let last = '0';
  let onEvent;
  const deliver = (events) => {
    if (!Array.isArray(events) || events.length > 128) throw new Error('Invalid event batch');
    // Validate the whole batch before publishing any of it.
    let previous = 0n;
    for (const item of events) {
      assertContract('Event', item);
      const seq = sequence(item.seq);
      if (seq === 0n || seq <= previous) throw new Error('Invalid event order');
      previous = seq;
    }
    for (const item of events) {
      if (sequence(item.seq) <= sequence(last)) continue;
      onEvent?.(item);
      last = item.seq;
    }
  };
  return {
    deliver,
    get lastSequence() {
      return last;
    },
    async request(method, after = '0') {
      if (!api.bridge_methods.includes(method)) throw new Error('Unknown bridge method');
      sequence(after);
      const raw = await native.postMessage(JSON.stringify({ version: api.version, method, after }));
      if (typeof raw !== 'string' || raw.length > 1048576) throw new Error('Invalid bridge reply');
      const reply = JSON.parse(raw);
      if (reply.version !== api.version) throw new Error('Bridge version mismatch');
      if (reply.error) throw new Error(reply.error);
      return reply.result;
    },
    async subscribe(callback, after = last) {
      sequence(after);
      onEvent = callback;
      last = after;
      deliver(await this.request('subscribe', after));
    },
  };
}
