// In-memory stand-in for the native backend, selected by `?demo=1`. It answers
// the same requests as transport.js so the real app runs unchanged on sample
// disks. It is a presentation aid: the authoritative editing rules are Zig's.
import { GIB, MIB } from './plan-model.js';

const hex = (n) => n.toString(16).padStart(64, '0');
const coded = (code) => Object.assign(Error(code), { code });
const byOffset = (a, b) => (BigInt(a.offset) < BigInt(b.offset) ? -1 : 1);
const EDITABLE = ['resize', 'format', 'delete', 'label'].map((operation) => ({
  operation,
  support: 'offline_check',
  reason: 'demo',
}));

function sampleDisk(n, path, model, table, capacity_gib, layout) {
  const capacity = BigInt(Math.round(capacity_gib * 1024)) * MIB;
  let at = MIB;
  const partitions = [];
  for (const [name, filesystem, gib, options = {}] of layout) {
    const length = BigInt(Math.round(gib * 1024)) * MIB;
    if (name !== null) {
      const used = (length * BigInt(options.used ?? 45)) / 100n;
      partitions.push({
        id: hex(n * 256 + partitions.length + 1),
        path: `${path}${/\d$/.test(path) ? 'p' : ''}${partitions.length + 1}`,
        offset: String(at),
        length: String(length),
        name,
        filesystem,
        used_bytes: String(used),
        free_bytes: String(length - used),
        mountpoints: options.mount ? [options.mount] : [],
        encryption: 'none',
        protected: !!options.protected,
        capabilities: options.protected ? [] : EDITABLE,
      });
    }
    at += length;
  }
  const gpt = table === 'gpt';
  return {
    path,
    identity: hex(n),
    capacity: String(capacity),
    sector_size: 512,
    model,
    read_only: false,
    partition_table: table,
    ...(gpt ? { usable_offset: String(MIB), usable_length: String(capacity - 2n * MIB) } : {}),
    partitions,
    diagnostics: gpt
      ? []
      : [{ code: 'demo', severity: 'info', message: 'MBR disks can be viewed, not edited.' }],
  };
}

function freshDisks() {
  return [
    sampleDisk(1, '/dev/nvme0n1', 'Samsung SSD 970 EVO Plus 1TB', 'gpt', 931.5, [
      ['EFI', 'vfat', 0.5, { protected: true, mount: '/boot/efi', used: 12 }],
      ['Arch', 'btrfs', 300, { mount: '/', used: 61 }],
      ['Data', 'ext4', 350, { mount: '/data', used: 38 }],
    ]),
    sampleDisk(2, '/dev/sda', 'WD Blue 2TB', 'gpt', 1863, [
      ['Windows', 'ntfs', 500, { used: 72 }],
      [null, null, 200],
      ['Media', 'ntfs', 900, { used: 55 }],
      ['Backup', 'ext4', 262.99, { used: 20 }],
    ]),
    sampleDisk(3, '/dev/sdb', 'SanDisk Ultra USB', 'mbr', 57.3, [['STICK', 'vfat', 57.2]]),
  ];
}

export function createDemoBackend(version) {
  let disks = freshDisks();
  let created = 0;
  let run = null;
  const snapshot = () => ({
    version,
    snapshot_id: hex(0xc0ffee),
    platform: 'linux',
    disks: structuredClone(disks),
    diagnostics: [],
  });

  const retained = (p) => ({
    id: p.id,
    offset: p.offset,
    length: p.length,
    name: p.name,
    filesystem: p.filesystem,
    retain_data: true,
  });

  function regionsOf(disk, layout) {
    const out = [];
    let at = BigInt(disk.usable_offset);
    const end = at + BigInt(disk.usable_length);
    const free = (offset, length) =>
      out.push({
        id: `free:${offset}`,
        offset: String(offset),
        length: String(length),
        name: '',
        free: true,
      });
    for (const p of layout) {
      const offset = BigInt(p.offset);
      if (offset > at) free(at, offset - at);
      const old = disk.partitions.find((x) => x.id === p.id);
      out.push({
        ...p,
        free: false,
        encryption: 'none',
        protected: old?.protected ?? false,
        capabilities: old?.capabilities ?? EDITABLE,
        ...(old ? { path: old.path, used_bytes: old.used_bytes, free_bytes: old.free_bytes } : {}),
      });
      at = offset + BigInt(p.length);
    }
    if (at < end) free(at, end - at);
    return out;
  }

  const allowed = (r, kind) =>
    r.free || (!r.protected && r.capabilities.some((c) => c.operation === kind));

  function apply(disk, layout, cmd) {
    const spans = regionsOf(disk, layout);
    const i = spans.findIndex((r) => r.id === cmd.partition_id);
    if (i < 0) throw coded('PartitionNotFound');
    const r = spans[i];
    const kind = ['delete', 'format', 'label'].includes(cmd.kind) ? cmd.kind : 'resize';
    if (!allowed(r, kind)) throw coded('OperationUnavailable');
    const sector = BigInt(disk.sector_size);
    const offset = BigInt(r.offset);
    const length = BigInt(r.length);
    const place = (region, at, size) => {
      if (region.free) return;
      Object.assign(
        layout.find((p) => p.id === region.id),
        { offset: String(at), length: String(size) },
      );
    };
    if (cmd.kind === 'resize') {
      const right = spans[i + 1];
      if (!right) throw coded('NoAdjacentRegion');
      if (!allowed(right, 'resize')) throw coded('OperationUnavailable');
      const total = length + BigInt(right.length);
      const n = (BigInt(cmd.length) / sector) * sector;
      if (n > total || n < (r.free ? 0n : sector) || total - n < (right.free ? 0n : sector))
        throw coded('InvalidPartitionRange');
      place(r, offset, n);
      place(right, offset + n, total - n);
      return r.id;
    }
    if (r.free && cmd.kind !== 'add_left' && cmd.kind !== 'add_right')
      throw coded('PartitionNotFound');
    if (cmd.kind === 'delete') {
      layout.splice(
        layout.findIndex((p) => p.id === r.id),
        1,
      );
      return null;
    }
    const target = layout.find((p) => p.id === r.id);
    if (cmd.kind === 'format') {
      if (!cmd.filesystem) throw coded('MissingFilesystem');
      Object.assign(target, { filesystem: cmd.filesystem, retain_data: false });
      return r.id;
    }
    if (cmd.kind === 'label') {
      target.name = cmd.name ?? '';
      return r.id;
    }
    const half = (length / 2n / sector) * sector;
    if (half < sector) throw coded('InsufficientFreeSpace');
    if (!cmd.filesystem) throw coded('MissingFilesystem');
    const left = cmd.kind === 'add_left';
    const new_length = r.free || left ? half : length - half;
    const new_offset = left ? offset : offset + length - new_length;
    if (!r.free) place(r, left ? offset + half : offset, left ? length - half : half);
    const id = hex(0xd00000 + ++created);
    layout.push({
      id,
      offset: String(new_offset),
      length: String(new_length),
      name: cmd.name ?? '',
      filesystem: cmd.filesystem,
      retain_data: false,
    });
    return id;
  }

  function intentsOf(disk, layout) {
    const intents = [];
    for (const old of disk.partitions) {
      const p = layout.find((x) => x.id === old.id);
      if (!p) {
        intents.push({ kind: 'delete', partition_id: old.id });
        continue;
      }
      if (p.offset !== old.offset || p.length !== old.length)
        intents.push({
          kind: p.length === old.length ? 'move' : 'resize',
          partition_id: p.id,
          offset: p.offset,
          length: p.length,
        });
      if (p.name !== old.name) intents.push({ kind: 'label', partition_id: p.id, label: p.name });
      if (!p.retain_data || p.filesystem !== old.filesystem)
        intents.push({ kind: 'format', partition_id: p.id, filesystem: p.filesystem });
    }
    for (const p of layout)
      if (!disk.partitions.some((old) => old.id === p.id))
        intents.push({
          kind: 'create',
          partition_id: p.id,
          offset: p.offset,
          length: p.length,
          filesystem: p.filesystem,
          label: p.name,
        });
    return intents;
  }

  function plan(req) {
    const disk = disks.find((d) => d.identity === req.disk_identity);
    if (!disk) throw coded('DiskIdentityNotFound');
    if (disk.partition_table !== 'gpt') throw coded('DiskNotEditable');
    const layout = (req.layout ?? disk.partitions.map(retained))
      .map((p) => ({ ...p }))
      .sort(byOffset);
    const selected = req.command ? apply(disk, layout, req.command) : undefined;
    layout.sort(byOffset);
    const intents = intentsOf(disk, layout);
    const draft = {
      version,
      snapshot_id: hex(0xc0ffee),
      disk_identity: disk.identity,
      intents,
      layout,
    };
    const result = { version, draft, regions: regionsOf(disk, layout) };
    if (selected) result.selected = selected;
    if (req.review) {
      const moved = intents.filter((i) => i.kind === 'move' || i.kind === 'resize');
      result.validated = {
        version,
        digest: hex(0xd16e57 + intents.length),
        executable: true,
        offline_validation_required: false,
        operations: intents,
        diagnostics: moved.length
          ? [
              {
                code: 'demo_data_transfer',
                severity: 'warning',
                message:
                  'Moving or shrinking a partition rewrites its data and can take a long time.',
              },
            ]
          : [],
        destructive_partitions: intents
          .filter(
            (i) =>
              i.kind === 'delete' ||
              (i.kind === 'format' && disk.partitions.some((p) => p.id === i.partition_id)),
          )
          .map((i) => i.partition_id),
        draft,
      };
    }
    return result;
  }

  function commit(draft) {
    const disk = disks.find((d) => d.identity === draft.disk_identity);
    let number = disk.partitions.length;
    disk.partitions = draft.layout.map((p) => {
      const old = disk.partitions.find((x) => x.id === p.id);
      const base = old ?? {
        id: p.id,
        path: `${disk.path}${/\d$/.test(disk.path) ? 'p' : ''}${++number}`,
        mountpoints: [],
        encryption: 'none',
        protected: false,
        capabilities: EDITABLE,
      };
      return {
        ...base,
        offset: p.offset,
        length: p.length,
        name: p.name,
        filesystem: p.filesystem,
      };
    });
  }

  function status() {
    if (!run) throw coded('SessionNotFound');
    const s = run.session;
    if (s.status === 'running') {
      if (s.cancel_requested)
        Object.assign(s, {
          status: 'cancelled',
          message: 'Stopped between steps. Completed steps remain on disk.',
        });
      else if (++s.completed >= s.total) {
        commit(run.draft);
        Object.assign(s, { status: 'succeeded', message: 'Every step finished and was verified.' });
      } else s.message = `Working on step ${s.completed + 1} of ${s.total}…`;
    }
    return structuredClone(s);
  }

  const delay = (value) => new Promise((resolve) => setTimeout(() => resolve(value), 120));
  return async function request(path, data = {}) {
    switch (path) {
      case '/api/session':
        return delay({
          version,
          writes_enabled: true,
          maintenance_available: false,
          formats: ['ext4', 'btrfs', 'xfs', 'ntfs', 'exfat', 'vfat'],
        });
      case '/api/inventory':
      case '/api/inventory/elevated':
        return delay(snapshot());
      case '/api/plan':
        return plan(data);
      case '/api/execute':
        run = {
          draft: data.draft,
          session: {
            version,
            id: hex(0x5e5510 + ++created),
            plan_digest: data.approved_digest,
            status: 'running',
            completed: 0,
            total: Math.max(1, data.draft.intents.length),
            message: 'Checking the disk before the first step…',
            cancel_requested: false,
          },
        };
        return delay(structuredClone(run.session));
      case '/api/status':
        return delay(status());
      case '/api/cancel':
        if (run) run.session.cancel_requested = true;
        return delay(status());
      default:
        throw coded('MaintenancePreparationUnavailable');
    }
  };
}
