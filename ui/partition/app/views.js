// Pure markup: every function maps application state to the slots of one
// screen. No DOM access, no requests, no state changes. Backend text is escaped.
import { esc } from './dom.js';
import { isCompressed, lane, planMarks } from './disk-map.js';
import { pizza, RECIPE_COLORS } from './pizza.js';
import {
  UNITS,
  capability,
  capabilityNote,
  displayName,
  formatBytes,
  formatUnits,
  regions,
} from './plan-model.js';

const DESTRUCTIVE = new Set(['delete', 'format']);
const RUN_HEADLINES = {
  prepared: 'Your plan is in motion.',
  running: 'Your plan is in motion.',
  succeeded: 'All set.',
  cancelled: 'Stopped between steps.',
};

const heading = (eyebrow, title, sub = '') =>
  `<p class="eyebrow">${eyebrow}</p><h1>${title}</h1>${sub ? `<p class="sub">${sub}</p>` : ''}`;

function button(action, label, { kind = 'quiet', disabled = false, busy = false } = {}) {
  return `<button type="button" class="btn btn-${kind}" data-action="${action}"${disabled || busy ? ' disabled' : ''}${busy ? ' aria-busy="true"' : ''}>${label}</button>`;
}
const short = (digest) => (digest ? `${digest.slice(0, 12)}…` : 'not assigned yet');
const platformName = (s) => (s.inventory?.platform === 'windows' ? 'Windows' : 'this system');
const baselineIds = (s) => s.baseline.filter((p) => !p.free).map((p) => p.id);

function diskFacts(d) {
  const table = d.partition_table ? d.partition_table.toUpperCase() : 'table not read';
  const count = `${d.partitions.length} partition${d.partitions.length === 1 ? '' : 's'}`;
  return `${formatBytes(d.capacity)} · ${esc(table)} · ${count} · ${d.sector_size} B sectors`;
}
function diskState(d) {
  if (d.read_only) return 'Read-only device';
  if (d.partition_table && d.partition_table !== 'gpt') return 'View only · not GPT';
  if (!d.identity || d.usable_length == null) return 'Needs authorization to plan';
  return '';
}

export function loading() {
  return { body: heading('ONE MOMENT', 'A little patience.', 'Reading the disks in this system…') };
}

export function offline(s) {
  return {
    body: `${heading('NOT CONNECTED', 'Let’s reconnect.', esc(s.error))}<p class="prose">Pizza could not read the real disks. Start it with <code>pizza</code>, or reconnect to the local preview server.</p>`,
    foot: `<a class="btn btn-quiet" href="?demo=1">Open the demo with sample disks</a>${button('reload', 'Retry connection', { kind: 'primary' })}`,
  };
}

export function disks(s) {
  const all = s.inventory.disks;
  const cards = all
    .map((d) => {
      const state = diskState(d);
      const spans = regions(d);
      const notes = (d.diagnostics ?? [])
        .map((item) => `<span class="disk-note">${esc(item.message)}</span>`)
        .join('');
      return `<button type="button" class="disk" data-action="open-disk" data-path="${esc(d.path)}">
        <span class="disk-id"><span class="path">${esc(d.path)}</span><span class="disk-model">${esc(d.model || 'Unknown model')}</span></span>
        <span class="disk-facts">${diskFacts(d)}${state ? `<span class="chip">${state}</span>` : ''}</span>
        ${spans.length ? lane({ regions: spans, baseline_ids: spans.filter((p) => !p.free).map((p) => p.id) }) : '<span class="lane lane-empty">No partitions were read.</span>'}
        ${notes}
        <span class="disk-go" aria-hidden="true">Open →</span>
      </button>`;
    })
    .join('');
  const general = (s.inventory.diagnostics ?? [])
    .map((item) => `<p class="notice">${esc(item.message)}</p>`)
    .join('');
  return {
    head: heading(
      'STEP 1 · CHOOSE',
      'Pick a disk.',
      'Read live from this system. Opening a disk changes nothing.',
    ),
    list: `${general}<div class="disk-list" aria-busy="${s.busy === 'refresh'}">${cards || '<p class="empty">No disks are visible. Connect one, then refresh.</p>'}</div>`,
    foot: `${button('refresh', 'Refresh disks', { busy: s.busy === 'refresh' })}${s.session.writes_enabled ? button('find-run', 'Find saved session', { busy: s.busy === 'find-run' }) : ''}${s.session.maintenance_available ? button('maintenance-import', 'Import maintenance result', { busy: s.busy === 'import' }) : ''}<span class="foot-space"></span>`,
  };
}

function accessNotice(s) {
  if (s.editable && s.session.writes_enabled) return '';
  const d = s.disk;
  const issue =
    s.session.execution_issue ??
    (!s.session.writes_enabled ? 'Administrator execution is unavailable in this session.' : null);
  const reason = d.read_only
    ? 'This device is read-only.'
    : d.partition_table && d.partition_table !== 'gpt'
      ? 'This disk does not use GPT. Pizza currently plans GPT disks only.'
      : 'Authorize disk access to read the full partition table. This only reads.';
  const can_authorize =
    !s.editable && !d.read_only && (!d.partition_table || d.partition_table === 'gpt');
  return `<div class="notice notice-access" role="note">
    <strong>${s.editable ? 'Plans can be drawn, but not applied yet' : 'View only'}</strong>
    <span>${esc(s.editable ? issue : reason)}${!s.editable && issue ? ` ${esc(issue)}` : ''}</span>
    ${can_authorize ? button('authorize', s.busy === 'authorize' ? 'Authorizing and reading…' : 'Authorize and read partitions', { busy: s.busy === 'authorize', disabled: !s.session.writes_enabled }) : ''}
    ${s.accessError ? `<span class="error" role="alert">${esc(s.accessError)}</span>` : ''}
  </div>`;
}

function inspector(s) {
  const p = s.parts.find((x) => x.id === s.selected);
  if (!p) return '<p class="empty">Select a region on the map.</p>';
  const i = s.parts.indexOf(p);
  const right = s.parts[i + 1];
  const created = !p.free && !s.baseline.some((x) => x.id === p.id);
  const end = p.offset + p.length;
  const unit = UNITS[s.unit];
  const facts = [
    ['Start', `${p.offset.toLocaleString('en-US')} B`],
    ['End', `${end.toLocaleString('en-US')} B`],
    ['Size', `${p.length.toLocaleString('en-US')} B`],
  ];
  if (p.used_bytes != null)
    facts.push([
      'Before changes',
      `${formatBytes(p.used_bytes)} used${p.free_bytes == null ? '' : ` · ${formatBytes(p.free_bytes)} free`}`,
    ]);

  const resize_note = !s.editable
    ? 'Full partition-table access is required before editing.'
    : !right
      ? p.free
        ? 'Free space at the end of the disk.'
        : capabilityNote(p, 'resize')
      : (capabilityNote(p, 'resize') ??
        (capability(right, 'resize') ? null : `${displayName(right)} cannot give or take space.`));
  const size_field = `<label class="field"><span class="field-name">Size</span>
      <span class="size-input"><input id="size-value" data-field="size" inputmode="decimal" autocomplete="off" value="${formatUnits(p.length, unit)}"${resize_note ? ' disabled' : ''}>
      <select id="size-unit" data-field="unit" aria-label="Size unit">${Object.keys(UNITS)
        .map((name) => `<option${name === s.unit ? ' selected' : ''}>${name}</option>`)
        .join('')}</select></span>
      <span class="field-hint">${resize_note ?? (right ? `Space is exchanged with ${esc(displayName(right))} on the right.` : 'Shrink this partition to create free space at the end of the disk.')}</span></label>`;

  let fields = size_field;
  let actions = '';
  if (p.free) {
    const blocked = !s.editable || !s.formats.length;
    actions = `${button('add-left', 'New partition at start', { disabled: blocked })}${button('add-right', 'New partition at end', { disabled: blocked })}`;
  } else {
    const label_note = s.editable ? capabilityNote(p, 'label') : '';
    const format_note = s.editable ? capabilityNote(p, 'format') : '';
    const keeps = p.retain_data !== false;
    const options = [
      keeps
        ? `<option value="" selected>Keep ${esc(p.filesystem ?? 'unknown')} and its data</option>`
        : '',
      ...s.formats.map(
        (fs) =>
          `<option value="${esc(fs)}"${!keeps && fs === p.filesystem ? ' selected' : ''}>Format as ${esc(fs)}</option>`,
      ),
    ].join('');
    fields += `<label class="field"><span class="field-name">Label</span>
        <input id="label" data-field="label" maxlength="1024" autocomplete="off" value="${esc(p.name)}"${!s.editable || label_note ? ' disabled' : ''}>
        ${label_note ? `<span class="field-hint">${esc(label_note)}</span>` : ''}</label>
      <label class="field"><span class="field-name">File system</span>
        <select id="filesystem" data-field="filesystem"${!s.editable || format_note || !s.formats.length ? ' disabled' : ''}>${options}</select>
        <span class="field-hint${keeps ? '' : ' warn'}">${esc(format_note ?? (created ? 'A new partition starts empty.' : keeps ? 'Formatting erases everything on this partition.' : 'Everything on this partition will be erased.'))}</span></label>`;
    const split_blocked = !s.editable || !capability(p, 'resize') || !s.formats.length;
    actions = `${button('add-left', 'Split off a partition before', { disabled: split_blocked })}${button('add-right', 'Split off a partition after', { disabled: split_blocked })}${button('delete', 'Delete partition', { kind: 'danger', disabled: !s.editable || !capability(p, 'delete') })}`;
  }

  return `<header class="inspector-head">
      <p class="eyebrow">${p.free ? 'FREE SPACE' : created ? 'NEW PARTITION' : 'PARTITION'}</p>
      <h2>${esc(displayName(p))}</h2>
      <p class="inspector-sub">${p.path ? `<span class="path">${esc(p.path)}</span> · ` : ''}${formatBytes(p.length)}${p.free ? '' : ` · ${esc(p.filesystem ?? 'unknown file system')}`}</p>
    </header>
    <div class="fields">${fields}</div>
    <div class="actions">${actions}</div>
    <dl class="facts">${facts.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join('')}</dl>`;
}

function describeIntent(intent, nameOf) {
  const name = esc(nameOf(intent.partition_id));
  switch (intent.kind) {
    case 'create':
      return [
        `Create ${esc(intent.label || 'a partition')}`,
        `${formatBytes(intent.length)} · ${esc(intent.filesystem ?? 'unformatted')}`,
      ];
    case 'delete':
      return [`Delete ${name}`, 'The partition and its data are removed.'];
    case 'format':
      return [
        `Format ${name}`,
        `New ${esc(intent.filesystem ?? '')} file system. Existing data is erased.`,
      ];
    case 'resize':
      return [`Resize ${name}`, `To ${formatBytes(intent.length)}`];
    case 'move':
      return [`Move ${name}`, `Data is rewritten at a new position.`];
    case 'label':
      return [`Rename ${name}`, `To “${esc(intent.label ?? '')}”`];
    default:
      return [`${esc(intent.kind.replaceAll('_', ' '))} ${name}`, ''];
  }
}

function changeList(s, intents) {
  const nameOf = (id) =>
    displayName(
      s.baseline.find((p) => p.id === id) ??
        s.parts.find((p) => p.id === id) ?? { name: 'partition' },
    );
  return intents
    .map((intent) => {
      const [title, detail] = describeIntent(intent, nameOf);
      return `<li class="change${DESTRUCTIVE.has(intent.kind) ? ' change-danger' : ''}"><span class="change-kind">${esc(intent.kind)}</span><span class="change-text"><strong>${title}</strong>${detail ? `<small>${detail}</small>` : ''}</span></li>`;
    })
    .join('');
}

// Keep the SVG's paint resources alive while the planned proportions are unchanged.
let pizza_key = '';
let pizza_markup = '';
function proportions(s) {
  const ids = baselineIds(s);
  const key = JSON.stringify([
    ids,
    s.selected,
    s.parts.map((p) => [p.id, String(p.length), displayName(p), !!p.free]),
  ]);
  if (key !== pizza_key) {
    pizza_key = key;
    const names = s.parts.map((p) => displayName(p)).join(', ');
    pizza_markup = pizza({
      parts: s.parts.map((p) => ({
        id: p.id,
        name: displayName(p),
        size: Number(p.length) / 1073741824,
        displaySize: formatBytes(p.length),
        recipe: p.free ? 7 : Math.max(0, ids.indexOf(p.id)) % 7,
      })),
      selected: s.selected,
      editable: true,
      callouts: false,
      label: `Planned partitions, to scale: ${names}`,
    });
  }
  return pizza_markup;
}

function pizzaLegend(s) {
  const ids = baselineIds(s);
  const total = s.parts.reduce((sum, p) => sum + p.length, 0n);
  return `<div class="pizza-legend" aria-label="Partition slices">${s.parts
    .map((p) => {
      const recipe = p.free ? 7 : Math.max(0, ids.indexOf(p.id)) % 7;
      const share = total ? Number((p.length * 1000n) / total) / 10 : 0;
      return `<button type="button" data-action="select" data-select="${esc(p.id)}" aria-pressed="${p.id === s.selected}" title="${esc(displayName(p))} · ${esc(p.filesystem ?? (p.free ? 'Unallocated' : 'Unknown'))}${p.protected ? ' · Protected' : ''}" style="--recipe:${RECIPE_COLORS[recipe]}"><span class="recipe-dot" aria-hidden="true"></span><span class="slice-name">${esc(displayName(p))}<small>${esc(p.filesystem ?? (p.free ? 'Unallocated' : 'Unknown'))}${p.protected ? ' · Protected' : ''}</small></span><span class="slice-size">${formatBytes(p.length)}<small>${share < 0.1 ? '&lt;0.1' : share}%</small></span></button>`;
    })
    .join('')}</div>`;
}

function lanes(s, { interactive }) {
  const ids = baselineIds(s);
  const changed = s.intents.length > 0;
  const marks = planMarks(s.baseline, s.parts);
  const grip = (i) =>
    interactive &&
    s.editable &&
    capability(s.parts[i], 'resize') &&
    capability(s.parts[i + 1], 'resize');
  const now = `<div class="lane-row"><span class="lane-tag">Now</span>${lane({ regions: s.baseline, baseline_ids: ids, marks: marks.now, selected: s.editable ? null : s.selected, selectable: interactive && !s.editable })}</div>`;
  const after = s.editable
    ? `<div class="lane-row lane-row-after${changed ? ' is-changed' : ''}"><span class="lane-tag">After</span>${lane({ regions: s.parts, baseline_ids: ids, marks: marks.after, selected: interactive ? s.selected : null, selectable: interactive, grip })}</div>`
    : '';
  const compressed = isCompressed(s.baseline) || isCompressed(s.parts);
  const hint =
    interactive && s.editable ? 'Drag a boundary, or select a region to edit it below.' : '';
  return `<div class="lanes">${now}${after}</div><p class="map-note">${[hint, compressed ? 'Order is exact; small regions are drawn wider than scale so they stay visible.' : ''].filter(Boolean).join(' ')}</p>`;
}

function partitionTable(s) {
  const marks = planMarks(s.baseline, s.parts).after;
  const names = { created: 'New', erased: 'Data erased', moved: 'Moved', resized: 'Resized' };
  return `<div class="partition-table-head"><h2>Partitions</h2><span class="fine">Select a row to inspect or edit</span></div>
    <table class="partition-table"><thead><tr><th scope="col">Name</th><th scope="col">Filesystem</th><th scope="col">Size</th><th scope="col">State</th></tr></thead>
    <tbody>${s.parts
      .map(
        (p) => `<tr${p.id === s.selected ? ' class="is-selected"' : ''}>
      <td><button type="button" data-action="select" data-select="${esc(p.id)}" aria-pressed="${p.id === s.selected}">${esc(displayName(p))}</button><span class="partition-path">${esc(p.path ?? (p.free ? 'Unallocated' : 'Planned partition'))}</span></td>
      <td>${esc(p.filesystem ?? '—')}</td><td class="partition-size">${formatBytes(p.length)}</td>
      <td><span class="partition-state${p.retain_data === false ? ' error' : ''}">${p.protected ? 'Protected' : p.encryption !== 'none' && !p.free ? 'View only' : (names[marks.get(p.id)] ?? (p.free ? 'Available' : 'Unchanged'))}</span></td></tr>`,
      )
      .join('')}</tbody></table>`;
}

function diskNavigation(s) {
  return `<p class="eyebrow">Devices</p><nav class="disk-navigation" aria-label="Disks">${s.inventory.disks.map((d) => `<button type="button" data-action="open-disk" data-path="${esc(d.path)}"${d.path === s.disk.path ? ' aria-current="true"' : ''}${s.busy ? ' disabled' : ''}><strong>${esc(d.model || 'Unknown disk')}</strong><span class="path">${esc(d.path)}</span><span>${formatBytes(d.capacity)}</span></button>`).join('')}</nav><p class="navigation-note">Planning does not write to disk. Review the complete changes before authorizing execution.</p>`;
}

export function plan(s) {
  const d = s.disk;
  return {
    head: `<div class="head-row"><div>${heading('DISK WORKSPACE', esc(d.model || 'Plan your disk'), `<span class="path">${esc(d.path)}</span> · ${diskFacts(d)}`)}</div>
      <div class="head-tools">${button('undo', 'Undo', { disabled: !s.canUndo })}${button('reset', 'Start over', { disabled: !s.intents.length })}</div></div>${accessNotice(s)}`,
    navigation: diskNavigation(s),
    pizza: `<figure class="partition-pizza"><figcaption><span class="eyebrow">YOUR DISK, SLICED</span><span>Planned partitions · to scale</span></figcaption><div class="pizza-stage">${proportions(s)}</div><p class="pizza-hint">Select a slice to inspect it. Small partitions are also available in the legend.</p></figure>`,
    legend: pizzaLegend(s),
    table: `<details class="layout-details"${s.layoutExpanded ? ' open' : ''}><summary>Exact layout, boundaries & partition table</summary><div class="layout-details-body">${lanes(s, { interactive: true })}${partitionTable(s)}</div></details>`,
    inspector: inspector(s),
    changes: `<div class="change-queue"><div class="changes-head"><h2>Pending changes</h2><span class="count">${s.intents.length}</span></div>
      ${s.intents.length ? `<ol class="changes">${changeList(s, s.intents)}</ol>` : `<p class="empty">${s.editable ? 'Nothing yet. The plan matches the disk, and nothing is written until you apply it.' : 'This disk is shown as read.'}</p>`}
      <p class="queue-note">Changes stay in this plan until you review and apply them.</p></div>`,
    foot: `${button('show-disks', '← Disks')}<span class="foot-space"></span>${button('review', 'Review plan →', { kind: 'primary', disabled: !s.editable || !s.intents.length, busy: s.busy === 'review' })}`,
  };
}

export function review(s) {
  const v = s.reviewed;
  const operations = v.operations ?? [];
  const diagnostics = v.diagnostics ?? [];
  const destructive = v.destructive_partitions ?? [];
  const has_error = diagnostics.some((d) => d.severity === 'error');
  const offline_run =
    v.offline_validation_required && s.session.maintenance_available && !has_error;
  const nameOf = (id) =>
    displayName(
      s.baseline.find((p) => p.id === id) ?? s.parts.find((p) => p.id === id) ?? { name: id },
    );

  const blocker = !operations.length
    ? 'There is nothing to apply.'
    : !s.session.writes_enabled
      ? (s.session.execution_issue ?? 'Administrator execution is unavailable.')
      : has_error
        ? 'Resolve the errors above, then review again.'
        : !(v.executable || offline_run)
          ? 'This plan cannot be applied as it stands.'
          : destructive.length && !s.ack
            ? 'Confirm the data loss to continue.'
            : '';
  const ack = destructive.length
    ? `<label class="ack"><input type="checkbox" data-field="ack"${s.ack ? ' checked' : ''}><span>I understand that everything on <strong>${destructive.map((id) => esc(nameOf(id))).join(', ')}</strong> will be permanently erased.</span></label>`
    : '';
  const notes = diagnostics
    .map(
      (d) =>
        `<li class="diagnostic diagnostic-${esc(d.severity)}"><strong>${esc(d.code.replaceAll('_', ' '))}</strong><span>${esc(d.message)}</span></li>`,
    )
    .join('');
  const where = offline_run
    ? `Runs after a restart, in the maintenance system. ${esc(platformName(s))} must not be using the disk.`
    : 'Runs now, in this system, with administrator rights.';
  const facts = [
    ['Target', `<span class="path">${esc(s.disk.path)}</span> · ${formatBytes(s.disk.capacity)}`],
    ['Where', where],
    v.transfer_bytes ? ['Data to move', formatBytes(v.transfer_bytes)] : null,
    v.recovery_bytes ? ['Recovery space', formatBytes(v.recovery_bytes)] : null,
    ['Approval', `<span class="path">${short(v.digest)}</span>`],
  ].filter(Boolean);

  return {
    head: heading('STEP 3 · REVIEW', 'Check it twice.', 'This is exactly what will be applied.'),
    map: lanes(s, { interactive: false }),
    body: `<section class="review-changes" tabindex="0" role="region" aria-label="Planned changes and checks">
        <div class="changes-head"><h2>Planned changes</h2><span class="count">${operations.length}</span></div>
        ${operations.length ? `<ol class="changes">${changeList(s, operations)}</ol>` : '<p class="empty">Your disk stays as it is.</p>'}
        ${notes ? `<h2 class="checks-title">Checks</h2><ul class="diagnostics">${notes}</ul>` : ''}
      </section>
      <aside class="review-summary" aria-label="Before you apply">
        <dl class="facts">${facts.map(([k, val]) => `<div><dt>${k}</dt><dd>${val}</dd></div>`).join('')}</dl>
        <p class="boundary">Steps run in this system cannot be undone as a whole. Steps run in maintenance can be undone there, back to the moment of restart.</p>
        ${ack}
        ${button('export-plan', 'Save plan as JSON')}
      </aside>`,
    foot: `${button('show-plan', '← Edit plan', { disabled: s.busy === 'execute' })}<span class="foot-note" role="status">${esc(blocker)}</span>${button('execute', offline_run ? 'Prepare maintenance restart' : 'Apply plan', { kind: 'primary', disabled: !!blocker, busy: s.busy === 'execute' })}`,
  };
}

export function run(s) {
  const r = s.run;
  const pending = r.status === 'prepared' || r.status === 'running';
  const title = RUN_HEADLINES[r.status] ?? 'Review the result.';
  return {
    body: `${heading('STEP 4 · APPLY', title)}
      <div class="run-card${r.status === 'succeeded' ? ' is-done' : ''}">
        <p class="run-message" role="status" aria-live="polite">${esc(r.message)}</p>
        <progress max="${Math.max(1, r.total)}" value="${r.completed}" aria-label="Steps completed"></progress>
        <p class="run-count">${r.completed} of ${r.total} steps completed${pending ? '' : ` · ${esc(r.status.replaceAll('_', ' '))}`}</p>
        <p class="boundary">Completed steps stay on disk. You can close this window; the work continues and the result is kept for you.</p>
      </div>`,
    foot: `${pending ? button('cancel-run', r.cancel_requested ? 'Stopping after this step…' : 'Stop after this step', { disabled: r.cancel_requested }) : button('save-report', 'Save report')}<span class="foot-space"></span>${pending ? '' : button('finish-run', 'Read the disks again →', { kind: 'primary' })}`,
  };
}

export function disconnected(s) {
  return {
    body: `${heading('STEP 4 · APPLY', 'Reconnect to your session.', 'The work may still be running.')}
      <p class="prose">${esc(s.error)}</p>
      <p class="prose">Disk operations that started keep going when this window loses them. Reconnect to read the recorded result before making another plan.</p>
      <p class="fine">Session <span class="path">${esc(s.runId ?? 'not identified yet')}</span></p>`,
    foot: `<span class="foot-space"></span>${button('reconnect', 'Reconnect as administrator', { kind: 'primary', busy: s.busy === 'reconnect' })}`,
  };
}

export function maintenance(s) {
  const m = s.maintenance;
  const prepared = m.phase === 'prepared';
  return {
    body: `${heading('STEP 4 · APPLY', m.phase === 'armed' ? 'Restart requested.' : 'Maintenance is prepared.', `Save your work before restarting ${esc(platformName(s))}.`)}
      <p class="prose" role="status">${esc(s.maintenanceError ?? m.message ?? 'Read the maintenance result when you return to this system.')}</p>
      <p class="prose">The maintenance system checks the approved plan before touching the disk. When it has verified the result, choose Accept or Undo on its screen, then come back here and import the result.</p>
      <p class="fine">Session <span class="path">${esc(m.id)}</span></p>`,
    foot: `${button('maintenance-import', 'Import maintenance result', { busy: s.busy === 'import' })}${prepared ? button('maintenance-cancel', 'Cancel preparation', { busy: s.busy === 'maintenance-cancel' }) : ''}<span class="foot-space"></span>${button('maintenance-reboot', 'Restart into maintenance', { kind: 'primary', disabled: !prepared, busy: s.busy === 'maintenance-reboot' })}`,
  };
}

export function receipt(s) {
  const r = s.receipt;
  return {
    body: `${heading('STEP 4 · APPLY', r.outcome === 'completed' ? 'Maintenance complete.' : 'Maintenance result.', 'The returned report was verified and saved.')}
      <p class="prose" role="status">${esc(r.message)}</p>
      <dl class="facts"><div><dt>Outcome</dt><dd>${esc(r.outcome.replaceAll('_', ' '))}</dd></div><div><dt>Session</dt><dd><span class="path">${esc(r.id)}</span></dd></div></dl>`,
    foot: `${button('save-receipt', 'Save report')}<span class="foot-space"></span>${button('reload', 'Read the disks again →', { kind: 'primary' })}`,
  };
}
