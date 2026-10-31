import { reviewWorkspace } from './review-layout.js';
import { partitionBarMarkup, bindPartitionBar } from './partition-bar.js';
import { diskDetailsMarkup, bindDiskDetails } from './disk-details.js';
import { inspectorMarkup, bindEditorLayout, updateInspectorSummary, placePartitionKey } from './editor-layout.js';
import { formatPickerMarkup, bindFormatPicker } from './format-picker.js';
import { pizza, pizzaIcon, COLORS, updatePizzaSelection, partitionLabelName } from './pizza.js';

const DISKS = [
  {
    id: 0,
    model: 'Samsung SSD 970 EVO',
    short: 'Samsung SSD 1TB',
    capacity: 931.5,
    display: '931.5 GB',
    system: 200,
    data: 300,
    created: 150,
    free: 281.5,
  },
  {
    id: 1,
    model: 'WD Blue SN580',
    short: 'WD Blue 2TB',
    capacity: 1800,
    display: '1.8 TB',
    system: 180,
    data: 1020,
    created: 200,
    free: 400,
  },
  {
    id: 2,
    model: 'SanDisk Ultra 3D',
    short: 'SanDisk SSD 512GB',
    capacity: 476.9,
    display: '476.9 GB',
    system: 80,
    data: 196.9,
    created: 100,
    free: 100,
  },
];
let disk_index = 0,
  page = 'welcome',
  selected = 'new',
  parts = [],
  next_id = 1,
  progress_timer = null;
let format_picker = null;
let partition_bar_ui = null;
let disposeDiskDetails = () => {};
let disposeEditor = () => {};
const app = document.querySelector('#app');
const escape = (s) =>
  String(s).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
const number = (n) => Number(n.toFixed(1)).toLocaleString('en-US', { maximumFractionDigits: 1 });
const disk = () => DISKS[disk_index];
const isFree = (p) => p.fs === 'Unallocated';
const free = () => ({ size: parts.filter(isFree).reduce((sum, p) => sum + p.size, 0) });
const minimum = (p) => (isFree(p) ? 0 : 10);
const sizeLimit = (p) =>
  p.size +
  [parts[parts.indexOf(p) - 1], parts[parts.indexOf(p) + 1]]
    .filter((q) => q && isFree(q))
    .reduce((sum, q) => sum + q.size, 0);
const active = () => parts.find((p) => p.id === selected);
const NAV_NAMES = ['Disk', 'Edit', 'Confirm', 'Done'];
function resetParts() {
  const d = disk();
  parts = [
    { id: 'system', name: 'System', size: d.system, fs: 'NTFS', recipe: 2, color: COLORS[0] },
    { id: 'data', name: 'Data', size: d.data, fs: 'NTFS', recipe: 3, color: COLORS[1] },
    { id: 'new', name: 'New Partition', size: d.created, fs: 'NTFS', recipe: 1, color: COLORS[2] },
    {
      id: 'free',
      name: 'Free Space',
      size: d.free,
      fs: 'Unallocated',
      recipe: 7,
      color: COLORS[3],
    },
  ];
  selected = 'new';
  next_id = 1;
}
resetParts();
function stepper(step) {
  return `<div class="stepper" aria-label="Step ${Math.min(step, 4)} of 4">${NAV_NAMES.map((n, i) => `<div class="step ${i + 1 === step ? 'current' : i + 1 < step ? 'complete' : ''}" ${i + 1 === step ? 'aria-current="step"' : ''}><span class="step-circle">${i + 1 < step ? '✓' : ''}</span><span>0${i + 1} ${n}</span></div>`).join('')}</div>`;
}
function heading(step, title, subtitle) {
  return `<div class="page-heading"><div class="eyebrow step-label">STEP ${step} / 4</div><h1>${title}</h1><p class="subtitle">${subtitle}</p></div>`;
}
function nav(step, back, next, label = 'Next') {
  return `<div class="page-nav"><button class="quiet-button" data-go="${back}"><span>←</span> Back</button>${stepper(step)}<button class="primary" data-go="${next}">${label}<span>→</span></button></div>`;
}
function toast(message) {
  const t = document.querySelector('.toast');
  t.textContent = message;
  t.classList.add('visible');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.remove('visible'), 2600);
}
function welcome() {
  return `<section class="page"><div class="welcome"><div class="welcome-copy"><span class="eyebrow">WELCOME TO PIZZA</span><h1>Pizza.</h1><p class="subtitle">Partition with precision.<br>Simple as a slice.</p><button class="primary" data-go="disk">Get Started <span>↗</span></button><div class="welcome-counter">YOUR SPACE. BEAUTIFULLY REIMAGINED.</div><div class="welcome-foot"><span class="tiny-feature"><span>◉</span>Visual</span><span class="tiny-feature"><span>◇</span>Simple</span><span class="tiny-feature"><span>♧</span>Considered</span></div></div><div class="welcome-art"><span class="orbit-label">a little room for more.</span>${pizza({ className: 'hero-pizza' })}<div class="art-note">GOOD DISKS MAKE GREAT DAYS.</div></div></div></section>`;
}
function diskDetails() {
  return `<div class="detail-title"><h3>Disk ${disk_index}</h3><span>SELECTED</span></div><dl><div><dt>Model</dt><dd>${disk().model}</dd></div><div><dt>Capacity</dt><dd>${disk().display}</dd></div><div><dt>Partition style</dt><dd>GPT</dd></div><div><dt>Status</dt><dd class="healthy">Healthy</dd></div></dl>`;
}
function selectDisk() {
  return `<section class="page disk-page">${heading(1, 'Select a Disk', 'Design demo · These are sample disks.')}<div class="workspace"><div class="disk-layout"><div class="disk-list" role="group" aria-label="Sample disks">${DISKS.map((d, i) => `<button class="disk-card ${disk_index === i ? 'selected' : ''}" data-disk="${i}" aria-pressed="${disk_index === i}"><span class="radio" aria-hidden="true"></span>${pizzaIcon(i)}<span class="disk-card-identity"><span class="disk-name">Disk ${i}</span><span class="disk-model">${d.short}</span></span><span class="disk-capacity"><strong>${d.display}</strong><small>GPT</small></span></button>`).join('')}</div>${diskDetailsMarkup('Sample disk details',diskDetails())}</div><p class="disk-tip"><span>ⓘ</span> Sample disks only. <a href="./">Connect to real disks →</a></p></div>${nav(1, 'welcome', 'edit')}</section>`;
}
function pizzaStage() {
  return `${pizza({ parts, editable: true, selected, label: 'Select a partition slice to edit', className: 'editor-pizza' })}<div class="stage-caption">Select a slice or its label to edit.</div>`;
}
function inspector() {
  const p = active(),
    unallocated = isFree(p);
  return `<div class="inspector-top"><span class="color-dot" style="background:${p.color}"></span><div><span class="eyebrow">${unallocated ? 'ROOM TO GROW' : 'SELECTED SLICE'}</span><h3>${escape(p.name)}</h3></div><span class="partition-number">0${parts.indexOf(p) + 1}</span></div><label class="field-label" for="partition-size">${unallocated ? 'Available space' : 'Partition size'}<span>${Math.round((p.size / disk().capacity) * 100)}% of disk</span></label><div class="size-field"><input id="partition-size" aria-label="Partition size in GB" type="number" min="10" max="${number(sizeLimit(p)).replaceAll(',', '')}" step="0.1" value="${p.size}" ${unallocated || p.id === 'system' ? 'disabled' : ''}><span>GB</span></div><div class="field-row"><div><label class="field-label" for="partition-label">Label</label><input id="partition-label" maxlength="24" value="${escape(p.name)}" ${unallocated || p.id === 'system' ? 'disabled' : ''}></div><div><span class="field-label" id="format-label">File system</span>${formatPickerMarkup(p.fs, unallocated || p.id === 'system')}</div></div><p class="inspector-note"><b>↗</b>${unallocated ? 'Add a slice to give this space a new purpose.' : p.id === 'system' ? 'System is protected in this preview. Select another slice to edit.' : 'Drag a divider on the bar below, or enter a size here.'}</p>`;
}
function partitionBar() {
  return partitionBarMarkup(parts, disk().capacity, selected);
}
function editor() {
  return `<section class="page edit-page"><div class="workspace edit-workspace"><div class="editor-context"><div class="edit-heading"><div><span class="eyebrow">STEP 2 / 4 · DEMO</span><h1>Slice Your Disk</h1><p class="subtitle">A little adjustment. A lot of possibility.</p></div><div class="disk-chip"><span></span> Disk ${disk_index} · ${disk().display}</div></div><div class="edit-toolbar"><button class="reset-button" id="reset">↺ Reset layout</button></div><div class="editor-key"></div></div><div class="editor"><div class="pizza-stage">${pizzaStage()}</div>${inspectorMarkup(inspector())}</div><div id="partition-bar">${partitionBar()}</div></div>${nav(2, 'disk', 'review')}</section>`;
}
function operations() {
  const original_data = disk().data + disk().created;
  const changes = [];
  const data = parts.find((p) => p.id === 'data');
  if (!data)
    changes.push({
      name: 'Delete partition',
      detail: `Data · ${number(original_data)} GB → unallocated`,
      sign: '−',
    });
  else if (data.size !== original_data)
    changes.push({
      name: 'Resize partition',
      detail: `Data · ${number(original_data)} GB → ${number(data.size)} GB`,
      sign: '↔',
    });
  parts
    .filter((p) => !['system', 'data'].includes(p.id) && !isFree(p))
    .forEach((p) =>
      changes.push({
        name: 'Create partition',
        detail: `${escape(p.name)} · ${number(p.size)} GB · ${p.fs}`,
        sign: '+',
      }),
    );
  if (data && data.fs !== 'NTFS')
    changes.push({
      name: 'Format partition',
      detail: `${escape(data.name)} · NTFS → ${data.fs}`,
      sign: '◇',
    });
  if (data && data.name !== 'Data')
    changes.push({ name: 'Rename partition', detail: `Data → ${escape(data.name)}`, sign: '↗' });
  return changes;
}
function review() {
  const changes = operations();
  const destructive = changes.some((c) => ['Format partition', 'Delete partition'].includes(c.name));
  const rows = changes.map((c) => `<div class="review-row"><span class="operation-icon" aria-hidden="true">${c.sign}</span><div><div class="operation-title">${c.name}</div><div class="operation-detail">${c.detail}</div></div><span class="operation-sign" aria-hidden="true">${c.sign}</span></div>`).join('');
  const diagnostics = destructive ? '<div class="review-note"><span class="note-mark" aria-hidden="true">!</span><div><strong>This plan includes a destructive operation.</strong><p>Formatting or deleting a partition removes its data. Review your selection carefully.</p></div></div>' : '';
  return `<section class="page review-page">${heading(3, 'Review & Confirm', 'Check your changes before applying them.')}${reviewWorkspace({operations:rows,diagnostics,artwork:pizza({parts}),device:'Disk '+disk_index,details:disk().display+' · GPT',saveId:'save-plan',saveLabel:'Save sample plan',count:changes.length,mode:'Design preview',notice:'This preview never writes to a disk. In the real app, back up important files before changing partitions.'})}${nav(3, 'edit', 'progress', 'Preview Apply')}</section>`;
}
function progress() {
  return `<section class="page progress-view scene-page"><div class="scene-workspace"><div class="scene-copy"><span class="eyebrow">SIMULATING YOUR PLAN</span><h1>A little patience.</h1><p class="subtitle">Good things come together, one slice at a time.</p></div><div class="scene-art">${pizza({ parts })}</div></div><div class="scene-actions"><div class="progress-track"><span style="width:0%"></span></div><p class="progress-status" aria-live="polite">Preparing the preview…</p></div></section>`;
}
function done() {
  return `<section class="page done scene-page"><div class="scene-workspace"><div class="scene-copy"><span class="eyebrow">STEP 4 / 4 · PREVIEW COMPLETE</span><h1>All Set!</h1><p class="subtitle">A little space. A fresh start.</p><p class="scene-description">Your plan, beautifully put together.<br>Good things come one slice at a time.</p></div><div class="done-art scene-art">${pizza({ parts })}<div class="done-check" aria-label="Complete">✓</div><i class="art-spark"></i><i class="art-spark two"></i><i class="art-spark three"></i></div></div><div class="scene-actions"><button class="primary" data-go="edit">Back to my plan <span>↗</span></button><p class="demo-note">Preview complete. Your disks are unchanged.</p>${stepper(5)}</div></section>`;
}
function go(next) {
  if (progress_timer) {
    clearInterval(progress_timer);
    progress_timer = null;
  }
  page = next;
  render();
  window.scrollTo({ top: 0, behavior: 'instant' });
  if (next === 'progress') simulate();
}
function render() {
  disposeDiskDetails();
  disposeEditor();
  format_picker?.destroy();
  format_picker = null;
  partition_bar_ui?.destroy();
  partition_bar_ui = null;
  app.innerHTML = (
    { welcome, disk: selectDisk, edit: editor, review, progress, done }[page] || welcome
  )();
  document.title = `${{ welcome: 'Pizza', disk: 'Select a Disk', edit: 'Slice Your Disk', review: 'Review & Confirm', progress: 'Previewing your plan', done: 'All Set' }[page]} — Pizza`;
  wire();
  disposeDiskDetails = bindDiskDetails(app.querySelector('.disk-detail'));
  disposeEditor = bindEditorLayout(app);
  if (page === 'edit') updateInspectorSummary(app,active().name,`${number(active().size)} GB`);
}
function choosePart(id) {
  if (id === selected || !parts.some((p) => p.id === id)) return;
  selected = id;
  updatePizzaSelection(app.querySelector('.editor-pizza'), selected);
  app.querySelectorAll('.legend-item').forEach((item) => {
    const is_selected = item.dataset.select === selected;
    item.classList.toggle('active', is_selected);
    item.setAttribute('aria-pressed', String(is_selected));
  });
  updateInspector();
  partition_bar_ui?.sync();
}
function updateInspector() {
  const p = active();
  updateInspectorSummary(app,p.name,`${number(p.size)} GB`);
  const unallocated = isFree(p);
  const locked = unallocated || p.id === 'system';
  const panel = app.querySelector('.inspector');
  panel.querySelector('.color-dot').style.background = p.color;
  panel.querySelector('.eyebrow').textContent = unallocated ? 'ROOM TO GROW' : 'SELECTED SLICE';
  panel.querySelector('h3').textContent = p.name;
  panel.querySelector('.partition-number').textContent = `0${parts.indexOf(p) + 1}`;
  panel.querySelector('label[for="partition-size"]').firstChild.textContent = unallocated
    ? 'Available space'
    : 'Partition size';
  panel.querySelector('.field-label span').textContent =
    `${Math.round((p.size / disk().capacity) * 100)}% of disk`;
  const max = sizeLimit(p);
  for (const id of ['partition-size']) {
    const input = panel.querySelector(`#${id}`);
    input.max = max;
    input.value = p.size;
    input.disabled = locked;
  }
  panel.querySelector('#partition-label').value = p.name;
  panel.querySelector('#partition-label').disabled = locked;
  format_picker.set(p.fs, locked);
  panel.querySelector('.inspector-note').lastChild.textContent = unallocated
    ? 'Add a slice to give this space a new purpose.'
    : p.id === 'system'
      ? 'System is protected in this preview. Select another slice to edit.'
      : 'Drag a divider on the bar below, or enter a size here.';
}
function refreshEditorLayout() {
  // Structural edits can rebuild the artwork, but never replay page entry.
  app.querySelector('.pizza-stage').innerHTML = pizzaStage();
  app.querySelector('#partition-bar').innerHTML = partitionBar();
  placePartitionKey(app);
  updateInspector();
  wireSliceSelection();
}
function updatePartLabels() {
  partition_bar_ui?.sync();
  const p = active();
  const slice = app.querySelector(`[data-part="${p.id}"]`);
  slice?.setAttribute('aria-label', `${p.name}, ${p.size} GB, selected`);
  const label = app.querySelector(`[data-label-part="${p.id}"]`);
  if (label) {
    label.querySelector('.partition-label-name').textContent = partitionLabelName(p.name);
    label.querySelector('.partition-label-fs').textContent = p.fs;
    label.querySelector('title').textContent = `${p.name} · ${p.size} GB · ${p.fs}`;
  }
  app.querySelector(`[data-select="${p.id}"]`).setAttribute('aria-label', `Select ${p.name}`);
  app.querySelector(`.legend-item[data-select="${p.id}"] .legend-name`).textContent = p.name;
}
function makeFree(size) {
  return {
    id: `free-${next_id++}`,
    name: 'Free Space',
    size,
    fs: 'Unallocated',
    recipe: 7,
    color: COLORS[3],
  };
}
function normalizeParts() {
  const previous_index = parts.findIndex((p) => p.id === selected),
    merged = [];
  for (const p of parts) {
    if (p.size <= 0) continue;
    const previous = merged.at(-1);
    if (isFree(p) && previous && isFree(previous)) {
      previous.size = Math.round((previous.size + p.size) * 10) / 10;
      if (selected === p.id) selected = previous.id;
    } else merged.push(p);
  }
  parts = merged;
  if (!parts.some((p) => p.id === selected))
    selected = parts[Math.max(0, Math.min(previous_index, parts.length - 1))].id;
}
function resize(value, preserve_input = false) {
  const p = active();
  if (p.id === 'system' || isFree(p)) return;
  const next = Math.round(Math.max(10, Math.min(sizeLimit(p), Number(value) || 10)) * 10) / 10;
  const delta = Math.round((next - p.size) * 10) / 10;
  if (!delta) return;
  const raw = app.querySelector('#partition-size').value;
  const index = parts.indexOf(p),
    left = parts[index - 1],
    right = parts[index + 1];
  if (delta < 0) {
    if (right && isFree(right)) right.size = Math.round((right.size - delta) * 10) / 10;
    else parts.splice(index + 1, 0, makeFree(-delta));
  } else {
    let remaining = delta;
    for (const neighbor of [right, left]) {
      if (!neighbor || !isFree(neighbor)) continue;
      const take = Math.min(remaining, neighbor.size);
      neighbor.size = Math.round((neighbor.size - take) * 10) / 10;
      remaining = Math.round((remaining - take) * 10) / 10;
    }
  }
  p.size = next;
  normalizeParts();
  refreshEditorLayout();
  if (preserve_input) app.querySelector('#partition-size').value = raw;
}
function resizeBoundary(left_id, right_id, value) {
  const index = parts.findIndex((p) => p.id === left_id),
    left = parts[index],
    right = parts[index + 1];
  if (!left || right?.id !== right_id || left.id === 'system' || right.id === 'system') return;
  const total = Math.round((left.size + right.size) * 10) / 10;
  const next =
    Math.round(Math.max(minimum(left), Math.min(total - minimum(right), value)) * 10) / 10;
  if (next === left.size) return;
  left.size = next;
  right.size = Math.round((total - next) * 10) / 10;
  app.querySelector('.pizza-stage').innerHTML = pizzaStage();
  updateInspector();
  partition_bar_ui.sync();
  wireSliceSelection();
}
function commitBoundary() {
  const focused = document.activeElement?.dataset.boundaryLeft;
  normalizeParts();
  refreshEditorLayout();
  if (focused) {
    const handle =
      app.querySelector(`[data-boundary-left="${focused}"]`) ||
      app.querySelector(`[data-select="${selected}"]`);
    handle?.focus({ preventScroll: true });
  }
}
function partitionAction(action, id) {
  const p = parts.find((p) => p.id === id);
  if (!p || p.id === 'system') return;
  choosePart(id);
  if (action === 'format') {
    if (!isFree(p)) format_picker.open();
    return;
  }
  const index = parts.indexOf(p);
  if (action === 'delete') {
    if (isFree(p)) return;
    const empty = makeFree(p.size);
    parts.splice(index, 1, empty);
    selected = empty.id;
    normalizeParts();
    refreshEditorLayout();
    toast('Slice removed from this plan.');
    return;
  }
  if (!['add-left', 'add-right'].includes(action)) return;
  const available = p.size - (isFree(p) ? 0 : 10);
  if (available < 10) return;
  const size = Math.min(150, available),
    serial = next_id++;
  const created = {
    id: `added-${serial}`,
    name: `New Partition ${serial}`,
    size,
    fs: 'NTFS',
    recipe: (serial + 2) % 8,
    color: ['#c69b51', '#a98279', '#7c9474'][(serial - 1) % 3],
  };
  p.size = Math.round((p.size - size) * 10) / 10;
  parts.splice(index + (action === 'add-right' ? 1 : 0), 0, created);
  selected = created.id;
  normalizeParts();
  refreshEditorLayout();
  toast(action === 'add-left' ? 'New slice added on the left.' : 'New slice added on the right.');
}
function wireSliceSelection() {
  app.querySelectorAll('[data-label-part]').forEach((label) => {
    label.onclick = () => choosePart(label.dataset.labelPart);
  });
  app.querySelectorAll('[data-part]').forEach((el) => {
    el.onclick = () => choosePart(el.dataset.part);
    el.onkeydown = (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        choosePart(el.dataset.part);
      }
    };
  });
}
function wire() {
  app.querySelectorAll('[data-go]').forEach((el) => (el.onclick = () => go(el.dataset.go)));
  app.querySelectorAll('[data-disk]').forEach(
    (el) =>
      (el.onclick = () => {
        const index = Number(el.dataset.disk);
        if (index === disk_index) return;
        disk_index = index;
        resetParts();
        app.querySelectorAll('[data-disk]').forEach((card) => {
          const is_selected = Number(card.dataset.disk) === disk_index;
          card.classList.toggle('selected', is_selected);
          card.setAttribute('aria-pressed', String(is_selected));
        });
        app.querySelector('.disk-detail-content').innerHTML = diskDetails();
      }),
  );
  if (page === 'edit') {
    wireSliceSelection();
    partition_bar_ui = bindPartitionBar(app.querySelector('.edit-workspace'), {
      getState: () => ({ parts, capacity: disk().capacity, selected }),
      select: choosePart,
      resizeBoundary,
      commit: commitBoundary,
      action: partitionAction,
    });
    document.querySelector('#partition-size').oninput = (e) => {
      const value = Number(e.target.value);
      if (e.target.value !== '' && value >= 10 && value <= sizeLimit(active())) resize(value, true);
    };
    document.querySelector('#partition-size').onchange = (e) => resize(e.target.value);
    document.querySelector('#partition-label').oninput = (e) => {
      active().name = e.target.value.trim() || 'Untitled';
      document.querySelector('.inspector-top h3').textContent = active().name;
      updatePartLabels();
    };
    document.querySelector('#partition-label').onchange = (e) => {
      const value = e.target.value.trim();
      active().name = value || 'Untitled';
      e.target.value = active().name;
      updatePartLabels();
    };
    format_picker = bindFormatPicker(app.querySelector('.format-picker'), (value) => {
      active().fs = value;
      updatePartLabels();
      toast(`File system set to ${value} in this plan.`);
    });
    document.querySelector('#reset').onclick = () => {
      resetParts();
      refreshEditorLayout();
      toast('Original preview layout restored.');
    };
  }
  if (page === 'review')
    document.querySelector('#save-plan').onclick = () => {
      const blob = new Blob(
        [
          JSON.stringify(
            {
              kind: 'pizza-design-preview',
              disk: { id: disk_index, model: disk().model, capacityGB: disk().capacity },
              partitions: parts,
              operations: operations(),
              executable: false,
            },
            null,
            2,
          ),
        ],
        { type: 'application/json' },
      );
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'pizza-sample-plan.json';
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      toast('Sample plan saved.');
    };
}
function simulate() {
  let value = 0;
  progress_timer = setInterval(() => {
    value = Math.min(100, value + 8);
    const track = app.querySelector('.progress-track span');
    if (!track) return;
    track.style.width = `${value}%`;
    app.querySelector('.progress-status').textContent =
      value < 32
        ? 'Checking the sample layout…'
        : value < 66
          ? 'Previewing partition changes…'
          : value < 100
            ? 'Putting the finishing touches on…'
            : 'Preview complete.';
    if (value === 100) {
      clearInterval(progress_timer);
      progress_timer = null;
      setTimeout(() => {
        if (page === 'progress') go('done');
      }, 450);
    }
  }, 220);
}
document.querySelector('.brand').onclick = (e) => {
  e.preventDefault();
  go('welcome');
};
const help = document.querySelector('#help-dialog');
document.querySelector('#help').onclick = () => help.showModal();
help
  .querySelectorAll('.close-dialog,.close-help')
  .forEach((el) => (el.onclick = () => help.close()));
help.onclick = (e) => {
  if (e.target === help) {
    const r = help.getBoundingClientRect();
    if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom)
      help.close();
  }
};
render();
