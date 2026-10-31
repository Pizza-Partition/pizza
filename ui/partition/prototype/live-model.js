// All executable geometry stays in BigInt. Number is used only for SVG ratios.
export const GIB = 1n << 30n;
export const displayName = (p) => p.free ? 'Free Space' : p.name || 'Untitled partition';
export const isFree = (p) => p.free === true;
export function formatBytes(bytes) {
  const n = BigInt(bytes);
  if (n < 1024n) return `${n} B`;
  if (n < 1048576n) return `${displayUnits(n, 1024n)} KiB`;
  if (n < GIB) return `${displayUnits(n, 1048576n)} MiB`;
  return `${displayGiB(n)} GiB`;
}
export function displayGiB(bytes) {
  return displayUnits(bytes, GIB);
}
function displayUnits(bytes, unit) {
  const hundredths = (BigInt(bytes) * 100n + unit / 2n) / unit;
  return `${hundredths / 100n}.${String(hundredths % 100n).padStart(2, '0')}`.replace(/\.?0+$/, '');
}
export function inputGiB(bytes) {
  const scale = 1000000000n;
  const value = (BigInt(bytes) * scale + GIB - 1n) / GIB;
  return `${value / scale}.${String(value % scale).padStart(9, '0')}`.replace(/\.?0+$/, '');
}
export function parseGiB(value, sector) {
  if (!/^\d+(\.\d{1,9})?$/.test(value)) throw Error('Enter a positive size, up to nine decimal places.');
  const [whole, fraction = ''] = value.split('.');
  const n = BigInt(whole) * GIB + BigInt(fraction || '0') * GIB / (10n ** BigInt(fraction.length));
  return n / BigInt(sector) * BigInt(sector);
}
export function regions(disk) {
  const parts = disk.partitions.map((p) => ({ ...p, offset: BigInt(p.offset), length: BigInt(p.length), retain_data: true }));
  parts.sort((a, b) => a.offset < b.offset ? -1 : a.offset > b.offset ? 1 : 0);
  if (disk.usable_offset == null || disk.usable_length == null) return parts;
  const result = [];
  let at = BigInt(disk.usable_offset);
  const end = at + BigInt(disk.usable_length);
  for (const p of parts) {
    if (at < p.offset) result.push({ id: `free:${at}`, offset: at, length: p.offset - at, name: '', free: true });
    result.push(p); at = p.offset + p.length;
  }
  if (at < end) result.push({ id: `free:${at}`, offset: at, length: end - at, name: '', free: true });
  return result;
}
export function capability(part, kind) {
  if (part.free) return true;
  return !part.protected && part.encryption === 'none' && part.capabilities?.some((c) => c.operation === kind && c.support !== 'unavailable');
}
// A serialized transport adapter: all editing rules and draft generation live
// in Zig. Queueing prevents rapid edits from overwriting a previous response.
export class PlanClient {
  constructor(send, inventory, disk, elevated = false) {
    this.send = send;
    this.base = {snapshot_id: inventory.snapshot_id, disk_identity: disk.identity, elevated};
    this.layout = undefined;
    this.pending = Promise.resolve();
  }
  edit(command, {review = false} = {}) {
    const operation = this.pending.then(async () => {
      const result = await this.send({...this.base, layout: this.layout, command, review});
      this.layout = result.draft.layout;
      return result;
    });
    this.pending = operation.catch(() => {});
    return operation;
  }
}
