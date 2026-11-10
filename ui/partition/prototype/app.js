// The controller: owns application state, talks to the backend, and decides
// which screen is shown. Markup lives in views.js; editing rules live in Zig.
import { createPainter, download } from './dom.js';
import { ExecutionMonitor } from './execution-client.js';
import {
  GIB,
  MIB,
  PlanClient,
  UNITS,
  formatBytes,
  formatUnits,
  parseSize,
  regions,
  toRegion,
} from './plan-model.js';
import * as views from './views.js';

const HEX64 = /^[a-f0-9]{64}$/;
const STEP_OF = {
  disks: 1,
  plan: 2,
  review: 3,
  run: 4,
  disconnected: 4,
  maintenance: 4,
  receipt: 4,
};
// Execution was refused before anything started: safe to stay on the review.
const REFUSED = new Set([
  'authorization_failed',
  'authorization_unavailable',
  'executable_changed',
  'PlanApprovalChanged',
  'PlanNotExecutable',
  'HostPreflightFailed',
]);
// The backend reports most failures by name only; say what they mean here.
const EXPLANATIONS = {
  StaleInventory: 'The disks changed since they were read. Go back to the disk list and refresh.',
  DiskIdentityNotFound: 'This disk is no longer connected. Go back to the disk list and refresh.',
  DiskNotEditable: 'This disk cannot be edited.',
  NoAdjacentRegion: 'There is nothing to the right of this region to exchange space with.',
  InvalidPartitionRange: 'That size does not fit between the neighbouring regions.',
  InsufficientFreeSpace: 'There is not enough room here for another partition.',
  OperationUnavailable: 'That change is not available for this partition.',
  PartitionNotFound: 'That partition is no longer part of the plan.',
  MissingFilesystem: 'No file system can be created in this session.',
  PlanTooLarge: 'The plan has too many partitions.',
  PlanApprovalChanged: 'The disk no longer matches the reviewed plan. Review it again.',
  PlanNotExecutable: 'The plan did not pass the final check. Review it again.',
  ExecutionInProgress: 'Another operation is already running.',
  MaintenanceSessionInProgress: 'A maintenance session is still open. Import or cancel it first.',
  AnotherMaintenanceSessionExists:
    'A maintenance session is still open. Import or cancel it first.',
  PrivilegedServiceUnavailable: 'The administrator service could not be reached.',
};
const explain = (error) => EXPLANATIONS[error.code] ?? error.message;

export async function startApp({ request, demo, storage, version }) {
  const painter = createPainter(document.querySelector('#app'));
  const toast = document.querySelector('.toast');
  const s = {
    screen: 'loading',
    demo,
    session: null,
    inventory: null,
    elevated: false,
    formats: [],
    disk: null,
    editable: false,
    baseline: [],
    parts: [],
    intents: [],
    selected: null,
    canUndo: false,
    unit: 'GiB',
    busy: null,
    error: null,
    accessError: null,
    reviewed: null,
    ack: false,
    run: null,
    runId: null,
    maintenance: null,
    maintenanceError: null,
    receipt: null,
  };
  let client = null;
  let inventory_revision = 0;
  let drag = null;
  let toast_timer;

  function note(message) {
    toast.textContent = message;
    toast.classList.add('visible');
    clearTimeout(toast_timer);
    toast_timer = setTimeout(() => toast.classList.remove('visible'), 6000);
  }
  function render() {
    painter.paint(s.screen, views[s.screen](s));
    const step = STEP_OF[s.screen] ?? 0;
    for (const item of document.querySelectorAll('[data-step]')) {
      const n = Number(item.dataset.step);
      item.classList.toggle('is-done', n < step);
      if (n === step) item.setAttribute('aria-current', 'step');
      else item.removeAttribute('aria-current');
    }
  }
  function show(screen) {
    // A message about the previous screen should not follow the user to the next.
    if (s.screen !== screen) toast.classList.remove('visible');
    s.screen = screen;
    s.busy = null;
    render();
  }
  /** Run `task` with a busy marker; failures are explained in a toast. */
  async function busy(name, task) {
    if (s.busy) return;
    s.busy = name;
    render();
    try {
      await task();
    } catch (error) {
      note(explain(error));
    } finally {
      if (s.busy === name) s.busy = null;
      render();
    }
  }

  // Session references survive a closed window. Losing one is not silent: the
  // work would still finish, but this window could no longer find its result.
  function record(key, valid) {
    const name = `pizza.${key}.v${version}`;
    let value = null;
    try {
      const stored = JSON.parse(storage?.getItem(name) ?? 'null');
      if (stored && valid(stored)) value = stored;
    } catch (error) {
      console.warn(`Ignoring unreadable ${name}:`, error);
    }
    return {
      get: () => value,
      set(next) {
        value = next;
        if (!storage) return;
        try {
          if (next) storage.setItem(name, JSON.stringify(next));
          else storage.removeItem(name);
        } catch (error) {
          console.warn(`Cannot store ${name}:`, error);
          if (next)
            note('This window cannot remember the session. Keep it open until the work finishes.');
        }
      },
    };
  }
  const last_run = record(
    'execution',
    (v) => HEX64.test(v.digest) && (v.id === null || HEX64.test(v.id)),
  );
  const last_maintenance = record('maintenance', (v) => HEX64.test(v.id) && HEX64.test(v.digest));

  const monitor = new ExecutionMonitor({
    request,
    remember: (id, digest) => last_run.set({ id, digest }),
    onUpdate(session) {
      if (session.actual) s.inventory = session.actual;
      s.run = session;
      show('run');
    },
    onDisconnected(error, id) {
      s.error = explain(error);
      s.runId = id ?? null;
      show('disconnected');
    },
  });

  const canPlan = (d) =>
    !!(d?.identity && d.partition_table === 'gpt' && !d.read_only && d.usable_length != null);

  async function boot() {
    monitor.stop();
    client = null;
    show('loading');
    try {
      s.session = await request('/api/session');
      s.formats = s.session.formats ?? [];
      s.inventory = await request('/api/inventory');
      s.elevated = false;
      inventory_revision++;
      const pending = last_maintenance.get();
      if (pending) showMaintenance({ id: pending.id, phase: pending.phase });
      else if (last_run.get())
        await monitor.resume(last_run.get().id, false, last_run.get().digest);
      else show('disks');
    } catch (error) {
      console.error('Pizza could not read the disk inventory:', error);
      s.error = explain(error);
      show('offline');
    }
  }

  async function refresh() {
    const revision = inventory_revision;
    const snapshot = await request(s.elevated ? '/api/inventory/elevated' : '/api/inventory');
    // A slower ordinary read must not replace a newer administrator snapshot.
    if (revision !== inventory_revision) return;
    s.inventory = snapshot;
    inventory_revision++;
  }

  function adopt(result) {
    s.parts = result.regions.map(toRegion);
    s.intents = result.draft.intents ?? [];
    s.canUndo = client.canUndo;
    s.selected =
      result.selected ?? (s.parts.some((p) => p.id === s.selected) ? s.selected : s.parts[0]?.id);
  }
  async function openDisk(path) {
    const disk = s.inventory.disks.find((d) => d.path === path);
    if (!disk) throw Error('That disk is no longer connected. Refresh the disk list.');
    const opened = canPlan(disk)
      ? new PlanClient((data) => request('/api/plan', data), s.inventory, disk, s.elevated)
      : null;
    const first = opened ? await opened.edit() : null;
    client = opened;
    Object.assign(s, {
      disk,
      editable: !!opened,
      accessError: null,
      reviewed: null,
      selected: null,
    });
    if (first) {
      adopt(first);
      s.baseline = s.parts;
    } else {
      s.baseline = s.parts = regions(disk);
      s.intents = [];
      s.canUndo = false;
    }
    s.selected = (s.parts.find((p) => !p.free) ?? s.parts[0])?.id ?? null;
    show('plan');
  }
  async function edit(command, options) {
    const editing = client;
    if (!editing) throw Error('Authorize disk access before editing.');
    const result = await (command === 'undo' ? editing.undo() : editing.edit(command, options));
    if (editing !== client) throw Error('The plan was reopened while this change was in flight.');
    adopt(result);
    return result;
  }
  async function mutate(command) {
    try {
      await edit(command);
    } catch (error) {
      note(explain(error));
      // Inputs and dragged segments may show a value the backend refused.
      painter.invalidate('map');
      painter.invalidate('inspector');
    }
    render();
  }
  const selectedPart = () => s.parts.find((p) => p.id === s.selected);

  async function authorize() {
    const path = s.disk.path;
    s.accessError = null;
    s.busy = 'authorize';
    render();
    try {
      const snapshot = await request('/api/inventory/elevated', {});
      if (!snapshot.disks.some((d) => d.path === path))
        throw Error('The selected disk is no longer connected. Go back and refresh the disk list.');
      s.inventory = snapshot;
      s.elevated = true;
      inventory_revision++;
      // The answer must not pull the user back into an editor they left.
      if (s.screen === 'plan' && s.disk.path === path) await openDisk(path);
    } catch (error) {
      s.accessError = explain(error);
    } finally {
      if (s.busy === 'authorize') s.busy = null;
      render();
    }
  }

  async function execute() {
    const plan = s.reviewed;
    s.busy = 'execute';
    render();
    if (plan.offline_validation_required) {
      try {
        const value = await request('/api/prepare', {
          draft: plan.draft,
          approved_digest: plan.digest,
        });
        last_maintenance.set({ id: value.id, digest: plan.digest, phase: value.phase });
        showMaintenance(value);
      } catch (error) {
        s.busy = null;
        note(explain(error));
        render();
      }
      return;
    }
    // Remember the approval first: if the reply is lost, the run is still findable.
    last_run.set({ id: null, digest: plan.digest });
    try {
      monitor.watch(
        await request('/api/execute', { draft: plan.draft, approved_digest: plan.digest }),
      );
    } catch (error) {
      if (REFUSED.has(error.code)) {
        last_run.set(null);
        s.busy = null;
        note(explain(error));
        render();
      } else {
        s.error = explain(error);
        s.runId = last_run.get()?.id ?? null;
        show('disconnected');
      }
    }
  }

  function showMaintenance(value) {
    monitor.stop();
    s.maintenance = value;
    s.maintenanceError = null;
    show('maintenance');
  }

  const actions = {
    reload: boot,
    refresh: () => busy('refresh', refresh),
    'open-disk': (el) => busy('open', () => openDisk(el.dataset.path)),
    'show-disks'() {
      client = null;
      show('disks');
    },
    'show-plan': () => show('plan'),
    authorize,
    select(el) {
      if (!s.parts.some((p) => p.id === el.dataset.select)) return;
      s.selected = el.dataset.select;
      render();
    },
    undo: () => mutate('undo'),
    reset: () => busy('open', () => openDisk(s.disk.path)),
    'add-left': () =>
      mutate({ kind: 'add_left', partition_id: s.selected, filesystem: s.formats[0] }),
    'add-right': () =>
      mutate({ kind: 'add_right', partition_id: s.selected, filesystem: s.formats[0] }),
    delete: () => mutate({ kind: 'delete', partition_id: s.selected }),
    review: () =>
      busy('review', async () => {
        const result = await edit(undefined, { review: true });
        s.reviewed = result.validated;
        s.ack = false;
        show('review');
      }),
    'export-plan': () => download(`pizza-plan-v${version}.json`, s.reviewed.draft),
    execute,
    'cancel-run': () => monitor.cancel(),
    'save-report': () => download(`pizza-report-${s.run.id}.json`, s.run),
    'finish-run'() {
      monitor.stop();
      last_run.set(null);
      return boot();
    },
    reconnect() {
      s.busy = 'reconnect';
      render();
      return monitor.resume(s.runId, true, last_run.get()?.digest);
    },
    'maintenance-reboot': () =>
      busy('maintenance-reboot', async () => {
        const pending = last_maintenance.get();
        try {
          const result = await request('/api/reboot', {
            session_id: pending.id,
            approved_digest: pending.digest,
          });
          last_maintenance.set({ ...pending, phase: result.phase });
          s.maintenance = result;
          s.maintenanceError = null;
        } catch (error) {
          s.maintenanceError = explain(error);
        }
      }),
    'maintenance-cancel': () =>
      busy('maintenance-cancel', async () => {
        const pending = last_maintenance.get();
        await request('/api/cancel', {
          session_id: pending.id,
          approved_digest: pending.digest,
          elevated: true,
        });
        last_maintenance.set(null);
        await boot();
        note('Maintenance preparation cancelled.');
      }),
    'maintenance-import': () =>
      busy('import', async () => {
        const pending = last_maintenance.get();
        s.receipt = await request('/api/complete', pending ? { session_id: pending.id } : {});
        last_maintenance.set(null);
        s.screen = 'receipt';
      }),
    'save-receipt': () => download(`pizza-maintenance-${s.receipt.id}.json`, s.receipt),
    home() {
      if (s.inventory && ['plan', 'review'].includes(s.screen)) actions['show-disks']();
    },
    help: () => document.querySelector('#help-dialog').showModal(),
    'close-help': () => document.querySelector('#help-dialog').close(),
  };

  const fields = {
    unit(el) {
      s.unit = el.value;
      render();
    },
    size(el) {
      const p = selectedPart();
      const value = el.value.trim();
      // The field shows a rounded size; leaving it untouched must not resize.
      if (value === formatUnits(p.length, UNITS[s.unit])) return;
      try {
        const length = parseSize(value, UNITS[s.unit], s.disk.sector_size);
        return mutate({ kind: 'resize', partition_id: p.id, length: String(length) });
      } catch (error) {
        note(error.message);
        painter.invalidate('inspector');
        render();
      }
    },
    label: (el) => mutate({ kind: 'label', partition_id: s.selected, name: el.value }),
    filesystem(el) {
      if (el.value)
        return mutate({ kind: 'format', partition_id: s.selected, filesystem: el.value });
    },
    ack(el) {
      s.ack = el.checked;
      render();
    },
  };

  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-action]');
    if (!el || el.disabled) return;
    if (el.tagName === 'A') e.preventDefault();
    Promise.resolve(actions[el.dataset.action]?.(el)).catch((error) => note(explain(error)));
  });
  document.addEventListener('change', (e) => {
    const handler = fields[e.target.dataset?.field];
    if (handler) Promise.resolve(handler(e.target)).catch((error) => note(explain(error)));
  });

  // Boundary handles. A drag only previews; the backend commits and checks it.
  const boundary = (e) => e.target.closest?.('[data-boundary]');
  const describe = (d) => `${formatBytes(d.length)} | ${formatBytes(d.pair - d.length)}`;
  document.addEventListener('pointerdown', (e) => {
    const grip = boundary(e);
    if (!grip || e.button !== 0) return;
    e.preventDefault();
    const index = Number(grip.dataset.boundary);
    const left = grip.previousElementSibling;
    const right = grip.nextElementSibling;
    const from = left.getBoundingClientRect().left;
    drag = {
      grip,
      index,
      left,
      right,
      from,
      width: right.getBoundingClientRect().right - from,
      grow: Number(left.dataset.grow) + Number(right.dataset.grow),
      pair: s.parts[index].length + s.parts[index + 1].length,
      length: null,
    };
    grip.setPointerCapture(e.pointerId);
    grip.classList.add('is-dragging');
  });
  document.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const fraction = Math.max(0, Math.min(1, (e.clientX - drag.from) / drag.width));
    const exact = (drag.pair * BigInt(Math.round(fraction * 1000000))) / 1000000n;
    // Whole mebibytes while dragging; exact sizes belong in the size field.
    drag.length = drag.pair > 4n * MIB ? (exact / MIB) * MIB : exact;
    drag.left.style.flexGrow = drag.grow * fraction;
    drag.right.style.flexGrow = drag.grow * (1 - fraction);
    drag.grip.dataset.readout = describe(drag);
  });
  function endDrag(commit) {
    if (!drag) return;
    const d = drag;
    drag = null;
    painter.invalidate('map');
    if (commit && d.length != null)
      mutate({ kind: 'resize', partition_id: s.parts[d.index].id, length: String(d.length) });
    else render();
  }
  document.addEventListener('pointerup', () => endDrag(true));
  document.addEventListener('pointercancel', () => endDrag(false));
  document.addEventListener('keydown', (e) => {
    const grip = boundary(e);
    if (!grip || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return;
    e.preventDefault();
    const index = Number(grip.dataset.boundary);
    const left = s.parts[index];
    const right = s.parts[index + 1];
    const sector = BigInt(s.disk.sector_size);
    const step = e.shiftKey ? GIB : MIB;
    let length = left.length + (e.key === 'ArrowLeft' ? -step : step);
    if (e.key === 'Home') length = left.free ? 0n : sector;
    if (e.key === 'End') length = left.length + right.length - (right.free ? 0n : sector);
    mutate({ kind: 'resize', partition_id: left.id, length: String(length) });
  });

  await boot();
}
