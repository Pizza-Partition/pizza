// Byte arithmetic and the plan-editing client. All executable geometry stays in
// BigInt; Number is used only for on-screen ratios. Editing rules live in Zig.
export const MIB = 1n << 20n;
export const GIB = 1n << 30n;
export const UNITS = { MiB: MIB, GiB: GIB };

export const isFree = (p) => p.free === true;
export const displayName = (p) => (p.free ? 'Free Space' : p.name || 'Untitled partition');
export const toRegion = (p) => ({ ...p, offset: BigInt(p.offset), length: BigInt(p.length) });

export function formatUnits(bytes, unit) {
  const hundredths = (BigInt(bytes) * 100n + unit / 2n) / unit;
  return `${hundredths / 100n}.${String(hundredths % 100n).padStart(2, '0')}`.replace(/\.?0+$/, '');
}
export const displayGiB = (bytes) => formatUnits(bytes, GIB);
export function formatBytes(bytes) {
  const n = BigInt(bytes);
  if (n < 1024n) return `${n} B`;
  if (n < MIB) return `${formatUnits(n, 1024n)} KiB`;
  if (n < GIB) return `${formatUnits(n, MIB)} MiB`;
  return `${formatUnits(n, GIB)} GiB`;
}
/** Lossless decimal GiB, rounded up, for round-tripping through text. */
export function inputGiB(bytes) {
  const scale = 1000000000n;
  const value = (BigInt(bytes) * scale + GIB - 1n) / GIB;
  return `${value / scale}.${String(value % scale).padStart(9, '0')}`.replace(/\.?0+$/, '');
}
/** Parse a decimal amount of `unit` bytes, rounded down to a whole sector. */
export function parseSize(value, unit, sector) {
  if (!/^\d+(\.\d{1,9})?$/.test(value))
    throw Error('Enter a positive size, up to nine decimal places.');
  const [whole, fraction = ''] = value.split('.');
  const n =
    BigInt(whole) * unit + (BigInt(fraction || '0') * unit) / 10n ** BigInt(fraction.length);
  return (n / BigInt(sector)) * BigInt(sector);
}
export const parseGiB = (value, sector) => parseSize(value, GIB, sector);

/** Physical-order regions of a disk as read; free spans only from verified usable bounds. */
export function regions(disk) {
  const parts = disk.partitions.map((p) => ({ ...toRegion(p), retain_data: true }));
  parts.sort((a, b) => (a.offset < b.offset ? -1 : a.offset > b.offset ? 1 : 0));
  if (disk.usable_offset == null || disk.usable_length == null) return parts;
  const result = [];
  const free = (offset, length) => ({ id: `free:${offset}`, offset, length, name: '', free: true });
  let at = BigInt(disk.usable_offset);
  const end = at + BigInt(disk.usable_length);
  for (const p of parts) {
    if (at < p.offset) result.push(free(at, p.offset - at));
    result.push(p);
    at = p.offset + p.length;
  }
  if (at < end) result.push(free(at, end - at));
  return result;
}

export function capability(part, kind) {
  if (part.free) return true;
  return (
    !part.protected &&
    part.encryption === 'none' &&
    !!part.capabilities?.some((c) => c.operation === kind && c.support !== 'unavailable')
  );
}
/** Why `kind` is unavailable on `part`, in words; null when it is available. */
export function capabilityNote(part, kind) {
  if (capability(part, kind)) return null;
  if (part.protected) return 'Boot and recovery partitions are protected.';
  if (part.encryption !== 'none') return 'Encrypted or unidentified volume: view only.';
  const reason = part.capabilities?.find((c) => c.operation === kind)?.reason;
  return reason
    ? `Not available: ${reason.replaceAll('_', ' ')}.`
    : 'Not available for this file system.';
}

// Serialized adapter over the backend editor. Queueing keeps rapid edits from
// overwriting an earlier response; the layout only ever comes from the backend.
export class PlanClient {
  constructor(send, inventory, disk, elevated = false) {
    this.send = send;
    this.base = { snapshot_id: inventory.snapshot_id, disk_identity: disk.identity, elevated };
    this.layout = undefined;
    this.history = [];
    this.pending = Promise.resolve();
  }
  get canUndo() {
    return this.history.length > 0;
  }
  edit(command, { review = false } = {}) {
    return this.enqueue(async () => {
      const result = await this.send({ ...this.base, layout: this.layout, command, review });
      if (command) this.history.push(this.layout);
      this.layout = result.draft.layout;
      return result;
    });
  }
  /** Re-derive the previous layout through the backend; history shrinks only on success. */
  undo() {
    return this.enqueue(async () => {
      if (!this.history.length) throw Error('Nothing to undo.');
      const result = await this.send({ ...this.base, layout: this.history.at(-1), review: false });
      this.history.pop();
      this.layout = result.draft.layout;
      return result;
    });
  }
  enqueue(task) {
    const operation = this.pending.then(task);
    // The caller receives the rejection; the queue itself must keep draining.
    this.pending = operation.catch(() => {});
    return operation;
  }
}
