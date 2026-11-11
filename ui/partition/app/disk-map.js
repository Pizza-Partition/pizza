// The disk map: one lane is the disk's address space, left to right. Order and
// adjacency are exact. Widths are proportional with a minimum, so a 100 MiB
// boot partition on a terabyte disk can still be seen, selected and dragged.
import { esc } from './dom.js';
import { displayName, formatBytes } from './plan-model.js';

// Crust, basil, mozzarella, mushroom, olive, pepper, aubergine.
const TONES = ['#b08d4f', '#6f7f4a', '#c9a13c', '#8c5f49', '#5d7f79', '#b5714a', '#85708f'];
const BADGES = {
  created: 'New',
  erased: 'Erase',
  removed: 'Delete',
  moved: 'Move',
  resized: 'Resize',
};

/** A partition keeps one colour in every lane; partitions new to the plan have none. */
export function toneOf(id, baseline_ids) {
  const index = baseline_ids.indexOf(id);
  return index < 0 ? null : TONES[index % TONES.length];
}

/** What the plan does to each region: `now` marks the disk as read, `after` the plan. */
export function planMarks(baseline, parts) {
  const now = new Map();
  const after = new Map();
  const planned = new Map(parts.map((p) => [p.id, p]));
  const existing = new Map(baseline.filter((p) => !p.free).map((p) => [p.id, p]));
  for (const id of existing.keys()) if (!planned.has(id)) now.set(id, 'removed');
  for (const p of parts) {
    if (p.free) continue;
    const old = existing.get(p.id);
    if (!old) after.set(p.id, 'created');
    else if (p.retain_data === false) after.set(p.id, 'erased');
    else if (p.offset !== old.offset) after.set(p.id, 'moved');
    else if (p.length !== old.length) after.set(p.id, 'resized');
  }
  return { now, after };
}

export const isCompressed = (regions) => {
  const total = regions.reduce((n, p) => n + p.length, 0n) || 1n;
  return regions.some((p) => p.length * 40n < total);
};

/**
 * `selectable` renders segments as buttons; `grip(i)` says whether the boundary
 * between region i and i+1 can be dragged.
 */
export function lane({ regions, baseline_ids, selected, marks, selectable = false, grip }) {
  const total = regions.reduce((n, p) => n + p.length, 0n) || 1n;
  const segments = regions.map((p, i) => {
    const grow = Number((p.length * 1000000n) / total) / 1000;
    const mark = marks?.get(p.id);
    const tone = p.free ? null : toneOf(p.id, baseline_ids);
    const classes = [
      'seg',
      p.free ? 'seg-free' : tone ? '' : 'seg-created',
      mark ? `seg-${mark}` : '',
      p.id === selected ? 'is-selected' : '',
    ]
      .filter(Boolean)
      .join(' ');
    const style = `flex-grow:${grow}${tone ? `;--tone:${tone}` : ''}`;
    const text = `${displayName(p)}, ${formatBytes(p.length)}${mark ? `, ${BADGES[mark]}` : ''}`;
    const body = `<span class="seg-name">${esc(displayName(p))}</span><span class="seg-size">${formatBytes(p.length)}</span>${mark ? `<span class="seg-badge">${BADGES[mark]}</span>` : ''}`;
    const segment = selectable
      ? `<button type="button" class="${classes}" style="${style}" data-grow="${grow}" data-action="select" data-select="${esc(p.id)}" aria-pressed="${p.id === selected}" title="${esc(text)}">${body}</button>`
      : `<span class="${classes}" style="${style}" title="${esc(text)}">${body}</span>`;
    const right = regions[i + 1];
    if (!right || !grip?.(i)) return segment;
    const share = Number((p.length * 100n) / (p.length + right.length));
    return `${segment}<span class="grip" role="slider" tabindex="0" data-boundary="${i}" aria-orientation="horizontal" aria-label="Boundary between ${esc(displayName(p))} and ${esc(displayName(right))}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${share}" aria-valuetext="${esc(displayName(p))} ${formatBytes(p.length)}, ${esc(displayName(right))} ${formatBytes(right.length)}"></span>`;
  });
  return `<div class="lane${selectable ? ' lane-live' : ''}">${segments.join('')}</div>`;
}
