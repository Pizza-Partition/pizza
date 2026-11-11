// Ingredient silhouettes adapted from the user's original src/Pizza.tsx artwork.
// The web treatment deliberately omits the native renderer's height fields.
let serial = 0;
export const COLORS = ['#a58c58', '#77834d', '#bf6249', '#c9bd9f'];
const PALETTES = [
  ['#e7b56e', '#fff0bd', '#e6b576', '#b25b3b', ['tomato', 'basil', 'cheese']],
  ['#e2b16f', '#f6d99a', '#dbac62', '#ae5438', ['pepperoni', 'pepperoni', 'basil']],
  ['#dfbb84', '#f5e7c1', '#d9c398', '#b09b74', ['mushroom', 'cheese', 'mushroom']],
  ['#dfbd7d', '#e6dfa4', '#bfca84', '#8e9c59', ['basil', 'olive', 'pepper']],
  ['#e8bc73', '#ffe8a5', '#edc66d', '#c68f42', ['pineapple', 'ham', 'cheese']],
  ['#e6bc88', '#f7dfb7', '#e8be97', '#c99272', ['shrimp', 'basil', 'shrimp']],
  ['#dba36a', '#eebc86', '#d99865', '#b15b3e', ['pepperoni', 'onion', 'pepper']],
  ['#dfc087', '#fff0c1', '#e6d5a0', '#c4af7e', ['cheese', 'bluecheese', 'cheese']],
];
const point = (r, a) => [r * Math.cos(a), r * Math.sin(a)];
const sector = (r, start, end) => {
  const [x, y] = point(r, start),
    [u, v] = point(r, end);
  return `M0 0L${x} ${y}A${r} ${r} 0 ${end - start > Math.PI ? 1 : 0} 1 ${u} ${v}Z`;
};
const arc = (r, start, end) => {
  const a = point(r, start),
    b = point(r, end);
  return `M${a}A${r} ${r} 0 ${end - start > Math.PI ? 1 : 0} 1 ${b}`;
};
const escape = (text) =>
  String(text).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
export function partitionLabelName(name) {
  let text = '',
    width = 0;
  for (const char of name) {
    width += char.codePointAt(0) > 255 ? 2 : 1;
    if (width > 15) return `${text}…`;
    text += char;
  }
  return text;
}

function partitionLabels(pieces, total, selected) {
  let angle = -Math.PI / 2;
  const labels = pieces.map((p) => {
    const amount = (p.size / total) * Math.PI * 2;
    const mid = angle + amount / 2;
    angle += amount;
    const [anchor_x, anchor_y] = point(172, mid);
    return {
      p,
      mid,
      side: Math.cos(mid) >= 0 ? 1 : -1,
      anchorX: anchor_x,
      anchorY: anchor_y,
      y: Math.sin(mid) * 210 + 5,
    };
  });
  const columns = [-1, 1].map((side) =>
    labels.filter((l) => l.side === side).sort((a, b) => a.y - b.y),
  );
  const rows = Math.max(...columns.map((column) => column.length));
  const height = Math.max(530, rows * 75 + 110);
  // Lay out each outer column in angular order, with room for three text lines.
  // Only the leader's anchor enters the pizza; every text block stays outside it.
  columns.forEach((column) => {
    const limit = Math.max(205, ((column.length - 1) * 75) / 2);
    column.forEach((label, i) => {
      label.y = Math.max(-limit, Math.min(limit, label.y));
      if (i) label.y = Math.max(label.y, column[i - 1].y + 75);
    });
    if (column.at(-1)?.y > limit) {
      column.at(-1).y = limit;
      for (let i = column.length - 2; i >= 0; i--)
        column[i].y = Math.min(column[i].y, column[i + 1].y - 75);
    }
  });
  return {
    height,
    markup: `<g class="partition-labels" aria-hidden="true">${labels
      .map(({ p, mid, side, anchorX: anchor_x, anchorY: anchor_y, y }) => {
        const active = p.id === selected;
        const offset = active ? 7 : 0;
        const ax = anchor_x + Math.cos(mid) * offset,
          ay = anchor_y + Math.sin(mid) * offset;
        const text_x = side * 247,
          end_x = side * 232,
          elbow_x = side * 211,
          line_y = y - 5;
        return `<g class="partition-label ${active ? 'is-selected' : ''}" data-label-part="${p.id}" data-angle="${mid}" data-anchor-x="${anchor_x}" data-anchor-y="${anchor_y}" data-line-y="${line_y}" data-side="${side}">
      <path class="partition-label-leader" d="M${ax} ${ay}L${elbow_x} ${line_y}H${end_x}"/>
      <circle class="partition-label-anchor" cx="${ax}" cy="${ay}" r="2.7"/>
      <circle class="partition-label-end" cx="${end_x}" cy="${line_y}" r="2"/>
      <rect class="partition-label-hit" x="${side > 0 ? 240 : -369}" y="${y - 19}" width="129" height="74"/>
      <text class="partition-label-name" x="${text_x}" y="${y}" text-anchor="${side > 0 ? 'start' : 'end'}">${escape(partitionLabelName(p.name))}</text>
      <text class="partition-label-size" x="${text_x}" y="${y + 24}" text-anchor="${side > 0 ? 'start' : 'end'}">${escape(p.displaySize ?? `${Number(p.size.toFixed(1)).toLocaleString('en-US')} GB`)}</text>
      <text class="partition-label-fs" x="${text_x}" y="${y + 46}" text-anchor="${side > 0 ? 'start' : 'end'}">${escape(p.fs)}</text>
      <title>${escape(p.name)} · ${escape(p.displaySize ?? `${p.size} GB`)} · ${escape(p.fs)}</title>
    </g>`;
      })
      .join('')}</g>`,
  };
}

function ingredients(id) {
  return `
<radialGradient id="${id}-salami"><stop stop-color="#d97c58"/><stop offset="1" stop-color="#b84f38"/></radialGradient>
<linearGradient id="${id}-leaf" x2="1" y2="1"><stop stop-color="#8f9c56"/><stop offset="1" stop-color="#62783f"/></linearGradient>
<g id="${id}-pepperoni"><circle r="13" fill="url(#${id}-salami)" stroke="#ad5138" stroke-width=".65"/><circle r="10.7" fill="none" stroke="#eb9970" stroke-width=".8"/>${[
    [0, -7],
    [6, -4],
    [-6, -3],
    [4, 4],
    [-5, 6],
    [8, 5],
    [-2, 0],
  ]
    .map(
      ([x, y], i) =>
        `<ellipse cx="${x}" cy="${y}" rx="${i % 2 ? 1 : 1.6}" ry="1" fill="#f1c68c" transform="rotate(${i * 25} ${x} ${y})"/>`,
    )
    .join('')}</g>
<g id="${id}-tomato"><circle r="13" fill="#d67a50" stroke="#bd6643" stroke-width=".6"/><circle r="10" fill="#e9a365" stroke="#f1bd7d" stroke-width="1.2"/>${[0, 120, 240].map((a) => `<g transform="rotate(${a})"><path d="M0 -1Q-11 -11 -2 -9Q4 -8 0 -1" fill="#c26740"/><ellipse cx="-4" cy="-6" rx=".9" ry="1.8" fill="#f9dfa0"/></g>`).join('')}<circle r="1.8" fill="#f8d59a"/></g>
<g id="${id}-basil"><path d="M-11 13C-18 -2 -8 -16 12 -14C18 3 9 15 -11 13" fill="url(#${id}-leaf)"/><path d="M-13 16L10 -12M-5 6L-7 -4M1 -1L10 0M4 -5L3 -11" fill="none" stroke="#bbc58b" stroke-width=".75"/></g>
<g id="${id}-mushroom"><path d="M-14 2C-19 -19 16 -22 16 1Q9 7 4 3L5 13Q0 17 -5 13L-4 3Q-10 7 -14 2" fill="#b7926c" stroke="#9a7957" stroke-width=".7"/><path d="M-13 1Q0 -7 14 1Q8 5 4 3L5 13Q0 17 -5 13L-4 3Q-10 6 -13 1" fill="#f7e5bc"/><path d="M-8 1L-6 -2M8 1L6 -2M0 4L0 12" fill="none" stroke="#c3a277" stroke-width="1"/><path d="M-10 -7Q-5 -12 2 -11" fill="none" stroke="#d5b58d" stroke-width="1.5"/></g>
<g id="${id}-olive"><ellipse rx="8" ry="10" fill="#657043"/><ellipse rx="3.6" ry="5" fill="#e2d895"/><path d="M-5 -5Q-7 0 -5 5" stroke="#9aa475" stroke-width="1.5" fill="none"/></g>
<g id="${id}-pepper"><path d="M-10 11Q-17 -1 -9 -11Q-2 -17 10 -8L6 -3Q-1 -9 -4 -4Q-9 1 -4 8Z" fill="#d79548"/><path d="M-8 8Q-13 -1 -7 -8Q-1 -12 6 -7" fill="none" stroke="#f5c46c" stroke-width="2"/></g>
<g id="${id}-pineapple"><path d="M-9 -12L9 -9L12 10L-9 12L-13 -2Z" fill="#e5b44e"/><path d="M-6 -7L5 -5L7 6L-5 8Z" fill="#f7d67e"/><path d="M-5 -6L5 6M4 -5L-4 7" stroke="#e7bc60" fill="none"/></g>
<g id="${id}-ham"><path d="M-12 -9Q-2 -14 11 -7L14 6Q2 15 -10 10Z" fill="#d69180"/><path d="M-10 -6Q1 -11 10 -5M-7 8Q0 10 10 5" stroke="#efbc9f" stroke-width="1.5" fill="none"/></g>
<g id="${id}-shrimp"><path d="M10 -7C-1 -20 -20 -5 -11 8C-5 20 13 13 12 3C9 -3 2 -3 1 3C3 10 -7 6 -5 0C-3 -6 3 -5 7 -2L15 -7L15 -13Z" fill="#df9d76"/><path d="M-10 -4L-4 -1M-11 3L-5 3M-6 10L-3 5M2 11L3 6" stroke="#f9d4a5" stroke-width="2.3"/></g>
<g id="${id}-onion"><path d="M-12 -8Q16 -20 12 9Q1 21 -12 -8Z" fill="none" stroke="#b98791" stroke-width="3"/><path d="M-11 -7Q12 -15 10 8Q1 16 -11 -7" fill="none" stroke="#eacac0" stroke-width="1.2"/></g>
<g id="${id}-cheese"><path d="M-11 -7Q-6 -15 2 -11Q14 -13 13 -2Q18 7 7 11Q-3 16 -10 8Q-17 4 -11 -7" fill="#fff3ce"/><path d="M-7 -7Q0 -11 7 -6" stroke="#fff9e7" stroke-width="1.5" fill="none"/></g>
<g id="${id}-bluecheese"><path d="M-11 -9L7 -12L13 8L-7 12Z" fill="#f6e6bc"/><path d="M-6 -6L-1 0L-4 6M5 -8L3 -1L8 5M-1 0L4 2" stroke="#9ca78c" stroke-width="1.4" fill="none"/></g>`;
}

export function pizza({
  parts = null,
  selected = null,
  editable = false,
  mini = false,
  label = 'Eight recipes, one whole pizza',
  className: class_name = '',
} = {}) {
  const id = `pizza${++serial}`;
  const pieces = (
    parts ||
    PALETTES.map((_, i) => ({ id: `recipe-${i}`, size: 1, recipe: i, name: 'Pizza slice' }))
  ).filter((p) => p.size > 0);
  const total = pieces.reduce((n, p) => n + p.size, 0);
  let angle = -Math.PI / 2;
  const defs = [],
    slices = [];
  pieces.forEach((p, i) => {
    const amount = (p.size / total) * Math.PI * 2,
      gap = Math.min(0.008, amount * 0.1),
      edge_inset = Math.min(0.015, amount * 0.12),
      start = angle + gap,
      end = angle + amount - gap,
      mid = (start + end) / 2;
    const recipe = p.recipe ?? i % 8,
      pal = PALETTES[recipe];
    const crust = sector(200, start, end),
      sauce = sector(185, start, end),
      cheese = sector(180, start, end);
    defs.push(
      `<clipPath id="${id}-clip-${i}"><path d="${sector(177, start, end)}"/></clipPath><clipPath id="${id}-crust-clip-${i}"><path d="${crust}"/></clipPath><radialGradient id="${id}-base-${i}" cx="35%" cy="30%" r="80%"><stop stop-color="${pal[1]}"/><stop offset="1" stop-color="${pal[2]}"/></radialGradient>`,
    );
    let topping = '';
    // Polar rows keep ingredients intentionally composed, even when a partition resizes.
    for (let row = 0; row < 5; row++) {
      const radius = 48 + row * 27;
      const count = Math.max(1, Math.round((radius * amount) / 37));
      for (let col = 0; col < count; col++) {
        const a = start + (amount * (col + 0.5 + (row % 2 ? 0.09 : -0.04))) / count;
        const [x, y] = point(radius + (col % 2 ? 3 : -2), a);
        const ingredient = pal[4][(row * 2 + col) % 3];
        const scale = (0.62 + (row % 3) * 0.13) * (mini ? 1.15 : 1);
        topping += `<use href="#${id}-${ingredient}" transform="translate(${x} ${y}) rotate(${row * 39 + col * 71 + recipe * 17}) scale(${scale})"/>`;
      }
    }
    let texture = '';
    for (let j = 0; j < Math.round(amount * 28); j++) {
      const r = 28 + ((j * 47) % 146),
        a = start + ((j * 0.618) % 1) * amount;
      const [x, y] = point(r, a);
      texture += `<ellipse cx="${x}" cy="${y}" rx="${1 + (j % 3)}" ry="${0.7 + (j % 2)}" fill="${j % 4 ? '#bb8648' : '#fff6d3'}" opacity="${j % 4 ? 0.23 : 0.75}" transform="rotate(${j * 29} ${x} ${y})"/>`;
      if (j % 9 === 0)
        texture += `<path d="M${x - 7} ${y}q1 -7 8 -5t6 8q-2 5 -9 3Z" fill="${pal[3]}" opacity=".13" transform="rotate(${j * 41} ${x} ${y})"/>`;
      if (j % 3 === 0)
        texture += `<path d="M${x + 3} ${y + 5}l2 -3m-1 1l2 1" fill="none" stroke="#7d824c" stroke-width=".7" opacity=".55"/>`;
    }
    let crust_spots = '';
    for (let j = 0; j < Math.max(4, Math.round(amount * 13)); j++) {
      const a = start + ((end - start) * (j + 0.5)) / Math.max(4, Math.round(amount * 13));
      const [x, y] = point(192 + ((j % 3) - 1) * 2, a);
      crust_spots += `<ellipse cx="${x}" cy="${y}" rx="${1.1 + (j % 2)}" ry="${2 + (j % 3)}" fill="#b68349" opacity=".4" transform="rotate(${(a * 180) / Math.PI} ${x} ${y})"/>`;
    }
    const active = editable && selected === p.id;
    const shift = active ? 9 : 2;
    const opacity = editable && !active ? 0.32 : 1;
    const attrs = editable
      ? `role="button" tabindex="0" aria-label="${escape(p.name)}, ${escape(p.displaySize ?? `${p.size} GB`)}${active ? ', selected' : ''}" aria-pressed="${active}" data-part="${p.id}" data-angle="${mid}"`
      : '';
    slices.push(
      `<g class="pizza-slice ${editable ? 'interactive' : ''}" ${attrs} style="opacity:${opacity};transform:translate(${Math.cos(mid) * shift}px,${Math.sin(mid) * shift}px)"><path d="${crust}" fill="${pal[0]}" stroke="#c59a62" stroke-width=".65" stroke-linejoin="round"/><path d="${sauce}" fill="${pal[3]}" opacity=".8"/><path d="${cheese}" fill="url(#${id}-base-${i})"/><g clip-path="url(#${id}-crust-clip-${i})"><path d="${arc(193, start + edge_inset, end - edge_inset)}" stroke="#f7dca7" stroke-width="6" stroke-linecap="round" fill="none" opacity=".6"/>${crust_spots}</g><g clip-path="url(#${id}-clip-${i})">${texture}${topping}</g><path d="${crust}" class="slice-outline"/></g>`,
    );
    angle += amount;
  });
  const callouts = editable ? partitionLabels(pieces, total, selected) : null;
  const view_box = callouts
    ? `-380 ${-callouts.height / 2} 760 ${callouts.height}`
    : '-232 -232 464 464';
  return `<svg class="pizza-svg ${class_name}" viewBox="${view_box}" role="${editable ? 'group' : 'img'}" aria-label="${label}"><defs>${ingredients(id)}${defs.join('')}</defs><circle r="218" fill="none" stroke="#ded5c0" stroke-width=".7"/><circle r="212" fill="#e9dfca" opacity=".25"/>${slices.join('')}${callouts?.markup ?? ''}</svg>`;
}

// Keep the SVG and its paint resources alive so interrupted transitions can
// continue from their current visual state, including on rapid repeated clicks.
export function updatePizzaSelection(root, selected) {
  root.querySelectorAll('[data-part]').forEach((slice) => {
    const active = slice.dataset.part === selected;
    const shift = active ? 9 : 2;
    const angle = Number(slice.dataset.angle);
    slice.style.opacity = active ? '1' : '.32';
    slice.style.transform = `translate(${Math.cos(angle) * shift}px,${Math.sin(angle) * shift}px)`;
    slice.setAttribute('aria-pressed', String(active));
    const label = slice.getAttribute('aria-label').replace(/, selected$/, '');
    slice.setAttribute('aria-label', `${label}${active ? ', selected' : ''}`);
  });
  root.querySelectorAll('[data-label-part]').forEach((label) => {
    const active = label.dataset.labelPart === selected;
    const offset = active ? 7 : 0;
    const angle = Number(label.dataset.angle);
    const ax = Number(label.dataset.anchorX) + Math.cos(angle) * offset;
    const ay = Number(label.dataset.anchorY) + Math.sin(angle) * offset;
    const y = Number(label.dataset.lineY),
      side = Number(label.dataset.side);
    label.classList.toggle('is-selected', active);
    label
      .querySelector('.partition-label-leader')
      .setAttribute('d', `M${ax} ${ay}L${side * 211} ${y}H${side * 232}`);
    const anchor = label.querySelector('.partition-label-anchor');
    anchor.setAttribute('cx', ax);
    anchor.setAttribute('cy', ay);
  });
}

export function pizzaIcon(index = 0) {
  return `<svg viewBox="0 0 60 60" class="disk-icon" aria-hidden="true"><circle cx="30" cy="30" r="25" fill="#ead4a4"/><circle cx="30" cy="30" r="21" fill="${['#efd496', '#e4d7a4', '#efc39b'][index % 3]}"/><circle cx="30" cy="30" r="24.5" fill="none" stroke="#bc915a" stroke-width="1"/><path d="M30 6V54M9.2 42L50.8 18M9.2 18L50.8 42" stroke="#f8f6ef" stroke-width="2.5"/>${[
    [23, 15],
    [43, 30],
    [20, 41],
  ]
    .map(
      ([x, y]) =>
        `<circle cx="${x}" cy="${y}" r="3.3" fill="#c57954"/><circle cx="${x}" cy="${y}" r="1.1" fill="#edbd83"/>`,
    )
    .join(
      '',
    )}<path d="M34 16Q40 15 40 21Q34 22 34 16M15 28Q20 24 23 29Q20 34 15 28M34 43Q39 38 42 42Q41 48 34 43" fill="#84935b"/></svg>`;
}
